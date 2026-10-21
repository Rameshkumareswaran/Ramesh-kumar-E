// AR_Open_Items_Clean
// Raw ERP open-items print (CSV) -> one tidy row per open document.
// Needs: pRepoPath, pAsOfDate, fnCleanText, fnParseDate, fnParseAmount, fnTermsDays, dimCustomer, dimRepAlias
let
    // ---- lookups kept at the top so they are easy to extend --------------------------------
    DocTypeMap = [
        INV = "Invoice", INVOICE = "Invoice",
        CN = "Credit Note", #"CR NOTE" = "Credit Note", #"CREDIT NOTE" = "Credit Note",
        DN = "Debit Note", #"DR NOTE" = "Debit Note",
        PMT = "On-Account Receipt", RCT = "On-Account Receipt", ADV = "On-Account Receipt",
        JV = "Journal"
    ],
    NoDueDateTypes = {"Credit Note", "On-Account Receipt", "Journal"},
    BillingTypes = {"Invoice", "Debit Note"},
    PlaceholderPO = {"N/A", "NA", "-", "--", "NIL", "NONE"},

    // ---- 1. load the print exactly as exported ---------------------------------------------
    Source = Csv.Document(
        File.Contents(pRepoPath & "\data\raw\raw_ar_open_items.csv"),
        [Delimiter = ",", Columns = 12, Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Named = Table.RenameColumns(
        Source,
        List.Zip({Table.ColumnNames(Source),
                  {"CustCode", "CustName", "DocNo", "DocType", "DocDate", "DueDate",
                   "Amount", "Curr", "Terms", "SalesRep", "PORef", "Remarks"}})
    ),

    // ---- 2. trim everything, blanks -> null -------------------------------------------------
    Trimmed = Table.TransformColumns(
        Named,
        List.Transform(Table.ColumnNames(Named), each {_, fnCleanText, type nullable text})
    ),

    // ---- 3. drop titles, page footers, repeated headers, customer totals, grand totals -----
    //         (a real document line always has a Type; the repeated header row has DocNo = "Doc No")
    DocLines = Table.SelectRows(Trimmed, each [DocType] <> null and [DocNo] <> "Doc No"),

    // ---- 4. customer code / name only print on the first line of a block -> fill down ------
    Filled = Table.FillDown(DocLines, {"CustCode", "CustName"}),

    // ---- 5. standardise code (c10023, C-10023, "C 10023" -> C10023) and join the master ----
    CodeFix = Table.TransformColumns(
        Filled,
        {{"CustCode", each Text.Upper(Text.Remove(_, {"-", " "})), type text}}
    ),
    JoinCust = Table.NestedJoin(CodeFix, {"CustCode"}, dimCustomer, {"CustCode"}, "Cust", JoinKind.LeftOuter),
    ExpandCust = Table.ExpandTableColumn(
        JoinCust, "Cust",
        {"CustomerName", "Region", "Segment", "DefaultTermsDays"},
        {"MasterName", "Region", "Segment", "DefaultTermsDays"}
    ),
    CustomerName = Table.AddColumn(
        ExpandCust, "CustomerName",
        each if [MasterName] <> null then [MasterName] else Text.Proper([CustName]), type text
    ),

    // ---- 6. document type and number --------------------------------------------------------
    DocTypeStd = Table.AddColumn(
        CustomerName, "DocTypeStd",
        each Record.FieldOrDefault(DocTypeMap, Text.Upper([DocType]), "Other"), type text
    ),
    DocNoStd = Table.AddColumn(
        DocTypeStd, "DocNoStd", each Text.Upper(Text.Remove([DocNo], {" "})), type text
    ),

    // ---- 7. dates, amounts, currency -------------------------------------------------------
    DocDateP = Table.AddColumn(DocNoStd, "DocDateP", each fnParseDate([DocDate]), type nullable date),
    DueDateP = Table.AddColumn(DocDateP, "DueDateP", each fnParseDate([DueDate]), type nullable date),
    AmountP = Table.AddColumn(DueDateP, "AmountP", each fnParseAmount([Amount]), type nullable number),
    Currency = Table.AddColumn(
        AmountP, "Currency",
        each
            let c = if [Curr] = null then null else Text.Upper([Curr])
            in  if c = null then "INR"
                else if List.Contains({"INR", "RS", "RS.", "₹"}, c) then "INR"
                else if List.Contains({"USD", "US$", "$"}, c) then "USD"
                else if List.Contains({"EUR", "€"}, c) then "EUR"
                else c,
        type text
    ),

    // ---- 8. credits and receipts must be negative, whatever the print showed ---------------
    AmountSigned = Table.AddColumn(
        Currency, "AmountSigned",
        each if [DocTypeStd] = "Credit Note" or [DocTypeStd] = "On-Account Receipt"
             then -Number.Abs([AmountP]) else [AmountP],
        type nullable number
    ),

    // ---- 9. terms: parse text, fall back to customer master default ------------------------
    TermsDays = Table.AddColumn(
        AmountSigned, "TermsDays",
        each
            if List.Contains(NoDueDateTypes, [DocTypeStd]) then 0
            else
                let t = fnTermsDays([Terms])
                in  if t <> null then t
                    else if [DefaultTermsDays] <> null then [DefaultTermsDays]
                    else 30,
        type number
    ),

    // ---- 10. due date: keep it if sane, otherwise doc date + terms --------------------------
    DueDateStd = Table.AddColumn(
        TermsDays, "DueDateStd",
        each
            if [DocDateP] = null then null
            else if [DueDateP] <> null and [DueDateP] >= [DocDateP] then [DueDateP]
            else Date.AddDays([DocDateP], [TermsDays]),
        type nullable date
    ),

    // ---- 11. sales rep through the alias table ---------------------------------------------
    RepKey = Table.AddColumn(
        DueDateStd, "RepKey",
        each if [SalesRep] = null then null else Text.Lower(Text.Select([SalesRep], {"a".."z", "A".."Z"})),
        type nullable text
    ),
    JoinRep = Table.NestedJoin(RepKey, {"RepKey"}, dimRepAlias, {"Alias"}, "Rep", JoinKind.LeftOuter),
    ExpandRep = Table.ExpandTableColumn(JoinRep, "Rep", {"SalesRep"}, {"SalesRepStd"}),
    SalesRepFinal = Table.AddColumn(
        ExpandRep, "SalesRepFinal",
        each if [SalesRepStd] <> null then [SalesRepStd] else "Unassigned", type text
    ),

    // ---- 12. PO reference placeholders and dispute flag ------------------------------------
    PORefClean = Table.AddColumn(
        SalesRepFinal, "PORefClean",
        each if [PORef] = null or List.Contains(PlaceholderPO, Text.Upper([PORef])) then null else [PORef],
        type nullable text
    ),
    IsDisputed = Table.AddColumn(
        PORefClean, "IsDisputed",
        each [Remarks] <> null and Text.Contains(Text.Lower([Remarks]), "disp"), type logical
    ),

    // ---- 13. data-quality flag: what did we have to fix on this row? -----------------------
    DataFlag = Table.AddColumn(
        IsDisputed, "DataFlag",
        each
            let
                billing = List.Contains(BillingTypes, [DocTypeStd]),
                items = {
                    if billing and [DueDateP] = null then "due date missing - derived from terms"
                    else if [DueDateP] <> null and [DocDateP] <> null and [DueDateP] < [DocDateP]
                         then "due date before doc date - rebuilt" else null,
                    if [Curr] = null then "currency blank - assumed INR" else null,
                    if [MasterName] = null then "customer not in master" else null,
                    if [Terms] = null and billing then "terms blank - master default" else null,
                    if [AmountP] <> null and [AmountP] <> [AmountSigned] then "sign corrected" else null
                },
                joined = Text.Combine(List.RemoveNulls(items), "; ")
            in
                if joined = "" then null else joined,
        type nullable text
    ),

    // ---- 14. keep the final columns, give them their final names ---------------------------
    Selected = Table.SelectColumns(
        DataFlag,
        {"CustCode", "CustomerName", "Region", "Segment", "DocNoStd", "DocTypeStd", "DocDateP",
         "DueDateStd", "TermsDays", "Currency", "AmountSigned", "SalesRepFinal", "PORefClean",
         "Remarks", "IsDisputed", "DataFlag"}
    ),
    Renamed = Table.RenameColumns(
        Selected,
        {{"DocNoStd", "DocNo"}, {"DocTypeStd", "DocType"}, {"DocDateP", "DocDate"},
         {"DueDateStd", "DueDate"}, {"AmountSigned", "Amount"}, {"SalesRepFinal", "SalesRep"},
         {"PORefClean", "PORef"}}
    ),

    // ---- 15. the page-break lines repeat the last line of the previous page ----------------
    Deduped = Table.Distinct(Renamed, {"CustCode", "DocNo", "DocType", "Amount"}),

    // ---- 16. ageing against the report date -------------------------------------------------
    DaysPastDue = Table.AddColumn(
        Deduped, "DaysPastDue", each Duration.Days(pAsOfDate - [DueDate]), Int64.Type
    ),
    AgingBucket = Table.AddColumn(
        DaysPastDue, "AgingBucket",
        each
            let d = [DaysPastDue]
            in  if d <= 0 then "Not due"
                else if d <= 30 then "1-30"
                else if d <= 60 then "31-60"
                else if d <= 90 then "61-90"
                else if d <= 180 then "91-180"
                else "180+",
        type text
    ),

    // ---- 17. final types, column order and sort --------------------------------------------
    Ordered = Table.ReorderColumns(
        AgingBucket,
        {"CustCode", "CustomerName", "Region", "Segment", "DocNo", "DocType", "DocDate", "DueDate",
         "TermsDays", "Currency", "Amount", "SalesRep", "PORef", "Remarks", "IsDisputed",
         "DaysPastDue", "AgingBucket", "DataFlag"}
    ),
    Typed = Table.TransformColumnTypes(
        Ordered,
        {{"DocDate", type date}, {"DueDate", type date}, {"TermsDays", Int64.Type},
         {"Amount", Currency.Type}}
    ),
    Sorted = Table.Sort(Typed, {{"CustCode", Order.Ascending}, {"DocDate", Order.Ascending}, {"DocNo", Order.Ascending}})
in
    Sorted
