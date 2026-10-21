# Cleaning steps

Query: `power_query/AR_Open_Items_Clean.pq`. Helper functions and lookups are in the same folder.

Row counts through the query:

| Stage | Rows |
|---|---:|
| Raw lines in the CSV | 670 |
| After removing titles, footers, headers, totals and blanks (`DocLines`) | 510 |
| After removing duplicates (`Deduped`) | 497 |

The 160 lines removed in `DocLines` break down as: 53 blank lines, 13 repeated column headers, 13 page footers, 62 customer and grand total lines, and 19 title and note lines.

## 1. Load

`Csv.Document` with `Columns = 12` and UTF-8. No header promotion, because the header row is repeated on every page. The columns are renamed from `Column1..12` to real names with `List.Zip`.

## 2. Trim everything (`fnCleanText`)

Removes non-breaking spaces and control characters, trims, collapses double spaces and turns empty text into `null`. This is done once for all columns, so later steps can test for `null` instead of `""`, and `Table.FillDown` works (it only fills nulls).

## 3. Keep document lines only

A document line always has a Type. Titles, page footers, subtotals and blank lines do not, so `[DocType] <> null` removes them. The repeated column header has a Type too ("Type"), so it is removed by `[DocNo] <> "Doc No"`.

## 4. Fill down

The customer code and name are printed on the first line of each customer block only (and sometimes again after a page break). Filling down after the filter is safe because the lines that were removed carry no customer information.

## 5. Customer code and master join

`c10031`, `C-10156` and `C 10156` all become `C10031` / `C10156`. The code is then joined to `dimCustomer` to pick up the master name, region, segment and default terms. The name in the report is ignored when the code is in the master. Customers that are not in the master keep their report name in proper case and get a flag.

## 6. Document type and number

Type codes are mapped with a record (`DocTypeMap`) to five types: Invoice, Credit Note, Debit Note, On-Account Receipt, Journal. To support a new code, add one line to the record. Document numbers have spaces removed and are upper-cased so that `hr/25-26/00412 ` and `HR/25-26/00412` compare equal.

## 7. Dates, amounts, currency

`fnParseDate` tries four explicit formats and handles Excel serial numbers separately. All formats are day-first, so there is no ambiguity between dd/mm and mm/dd. `fnParseAmount` strips `Rs.`, the rupee sign and commas (lakh grouping is no different from thousand grouping once commas are gone), and treats brackets, a trailing minus or a leading minus as negative. Currency text is mapped to ISO codes.

## 8. Sign by document type

Credit notes and on-account receipts are set to `-Number.Abs(amount)`. Whatever the print shows, the result is negative. Journals keep the sign they were printed with.

## 9. Terms

`fnTermsDays` returns the number of days (30 from `Net 30`, `N30`, `30D`), 0 for words like COD or On receipt, and `null` if there is nothing. For invoices and debit notes, `null` falls back to the customer's default terms. Credit notes, receipts and journals are 0.

## 10. Due date

If the printed due date parses and is not earlier than the document date it is kept. Otherwise it is rebuilt as document date + terms days. This covers both blank due dates and the ones with the wrong year.

## 11. Sales rep

The rep name is reduced to lower-case letters only (`Ramesh K.` becomes `rameshk`) and joined to `dimRepAlias`. Anything without a match, including blank, becomes `Unassigned`.

## 12. PO reference and disputes

`N/A`, `NA`, `-`, `nil` and `none` are set to null. `IsDisputed` is true when the remark contains "disp" (Disputed, dispute, DISP, disputing).

## 13. DataFlag

One text column listing what was assumed or fixed on that row, separated by semicolons:

- due date missing - derived from terms
- due date before doc date - rebuilt
- currency blank - assumed INR
- customer not in master
- terms blank - master default
- sign corrected

Filter this column in the cleaned sheet to get the list of lines worth a second look.

## 14-15. Final columns and duplicates

The working columns are dropped and the rest renamed. `Table.Distinct` on customer code + document number + type + amount then removes the repeated lines. This has to happen after standardising, because the repeated lines are not always typed exactly the same (`HR/25-26/00412` vs `hr/25-26/00412`).

## 16. Ageing

`DaysPastDue = pAsOfDate - DueDate`, then buckets: Not due, 1-30, 31-60, 61-90, 91-180, 180+. Credits and receipts are aged on their own date like everything else, which is a simplification; some teams age unapplied credits separately.

## 17. Types and sort

Dates as `date`, amount as fixed decimal (`Currency.Type`), days as whole numbers. Sorted by customer code, document date, document number.
