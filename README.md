# AR open items: cleaning a messy ERP export with Power Query

Open-items reports out of an ERP are never ready to use. Titles and page footers in the middle of the data, customer names only printed once per block, amounts stored as text with brackets and trailing minus signs, dates typed six different ways. This repo takes one of those exports and turns it into a clean table using Power Query only. No VBA, no manual edits, so the same query can be refreshed on next month's file.

The example is a receivables open-items print for a small industrial supplies distributor: 497 open items across 59 customers, as on 30 September 2026.

## What is in the repo

```
ar-open-items-power-query/
├── AR_Open_Items_Power_Query.xlsx   raw, cleaned, before/after, issue log, ageing, M code
├── data/
│   ├── raw/raw_ar_open_items.csv    the export as it came, 670 lines
│   ├── lookups/                     customer master, sales rep alias table
│   └── clean/cleaned_ar_open_items.csv   output of the query, 497 rows
├── power_query/                     the M code (one file per query)
└── docs/
    ├── cleaning_steps.md            step by step, with the reason for each step
    └── data_dictionary.md           columns in the cleaned table
```

## The raw file

`data/raw/raw_ar_open_items.csv` looks like a printed report saved as CSV. 670 lines, of which only 510 are document lines. Things that need dealing with:

- Report title, run date, page footers, repeated column headers every page, blank lines, a customer total after each block and grand totals at the end (160 lines that are not documents)
- Customer code and name only printed on the first line of each customer block (439 lines have them blank)
- The same customer spelled differently, customer codes in different cases and with dashes
- Dates as `14/03/2026`, `14-Mar-26`, `2026-03-14`, `14.03.2026`, `14 Mar 2026` and Excel serial numbers like `46095`, all stored as text
- Amounts as text: `(22,900.00)`, `20,619.99-`, `Rs. 84,684.97`, `₹ 1,24,500.00`
- Credit notes and receipts that sometimes print as positive numbers
- Currency written several ways, sometimes blank
- Terms as `Net 30`, `NET30`, `30D`, `N30`, `COD`, `On receipt`, or blank
- Due dates that are blank, or typed with the wrong year so they fall before the invoice date
- Sales rep names spelled five ways each
- 13 lines that are repeated at the top of the next page or posted twice

`docs/cleaning_steps.md` and the *Issues_Log* sheet in the workbook have the full list with counts.

## Before and after

Raw lines (only the first ten columns shown, values in backticks as they appear in the file):

| Cust Code | Customer Name | Doc No | Type | Doc Date | Due Date | Amount | Curr | Terms | Sales Rep |
|---|---|---|---|---|---|---|---|---|---|
|  |  | `HR/26-27/01487` | `INV` | `46260` | `46275` | `50,268.00` | `INR` | `Net 15` | `Anitha Rao` |
|  |  | `CN/26-27/0118` | `CN` | `17/09/2026` | `17/09/2026` | `(22,900.00)` | `INR` |  | `Suresh Babu` |
|  |  | `CN/26-27/0134` | `Cr Note` | `19-Sep-26` | `19-Sep-26` | `5,500.00` | `INR` | `Immediate` | `SURESH B` |
|  |  | `HR/26-27/00716` | `INV` | `11-Jul-26` | `10-Aug-26` | `Rs. 224,663.47` | `INR` | `30 Days` | `Anitha R.` |
|  |  | `HR/25-26/04023` | `INV` | `29/03/2026` |  | `39,270.00` | `₹` | `Net 30` | `Anitha Rao` |

The same documents after the query:

| CustCode | CustomerName | DocNo | DocType | DocDate | DueDate | Amount | Currency | TermsDays | SalesRep | DataFlag |
|---|---|---|---|---|---|---|---|---|---|---|
| C10008 | Sagar Polypack | HR/26-27/01487 | Invoice | 2026-08-26 | 2026-09-10 | 50268.00 | INR | 15 | Anitha Rao |  |
| C10037 | Malnad Agro Foods Pvt Ltd | CN/26-27/0118 | Credit Note | 2026-09-17 | 2026-09-17 | -22900.00 | INR | 0 | Suresh Babu |  |
| C10171 | Anand Electricals | CN/26-27/0134 | Credit Note | 2026-09-19 | 2026-09-19 | -5500.00 | INR | 0 | Suresh Babu | sign corrected |
| C10008 | Sagar Polypack | HR/26-27/00716 | Invoice | 2026-07-11 | 2026-08-10 | 224663.47 | INR | 30 | Anitha Rao |  |
| C10008 | Sagar Polypack | HR/25-26/04023 | Invoice | 2026-03-29 | 2026-04-28 | 39270.00 | INR | 30 | Anitha Rao | due date missing - derived from terms |

The *Before_After* sheet in the workbook has 30 more examples, one per kind of problem, with the query step that fixes each.

## How to run it

1. Clone or unzip the repo somewhere on your machine.
2. In Excel go to Data > Get Data > From Other Sources > Blank Query (or Power BI Desktop: Transform data > New Source > Blank Query).
3. Create the two parameters first (Home > Manage Parameters > New Parameter): `pRepoPath`, the folder you cloned to, and `pAsOfDate`, `30/09/2026`. The values to use are in `power_query/pRepoPath.pq` and `pAsOfDate.pq`.
4. For every other `.pq` file, add a blank query, open the Advanced Editor, paste the file contents and **name the query exactly like the file** (`fnParseDate`, `dimCustomer`, and so on). The queries call each other by name.
5. Order does not matter for loading, but `AR_Open_Items_Clean` needs all the `fn*` and `dim*` queries to exist. `AR_Aging_Summary` builds on `AR_Open_Items_Clean`.
6. Close & Load `AR_Open_Items_Clean` and `AR_Aging_Summary`. Refresh when you get a new export. Drop the new file over `data/raw/raw_ar_open_items.csv`, or change the path in the `Source` step.

## What the main query does

The steps are numbered in the comments of `power_query/AR_Open_Items_Clean.pq`.

1. Load the CSV with 12 fixed columns and name them
2. Trim every column, replace non-breaking spaces, turn empty text into null (`fnCleanText`)
3. Keep only real document lines (those with a Type, minus the repeated header row)
4. Fill down customer code and name
5. Standardise the customer code and join the customer master for name, region, segment and default terms
6. Standardise document type and document number
7. Parse dates (`fnParseDate`), amounts (`fnParseAmount`) and currency
8. Make credit notes and on-account receipts negative
9. Work out payment terms in days (`fnTermsDays`), falling back to the master default
10. Keep a sensible due date, otherwise rebuild it from doc date + terms
11. Map sales rep spellings through the alias table
12. Clean the PO reference, derive an `IsDisputed` flag from the remarks
13. Write a `DataFlag` text on every row where something had to be assumed or corrected
14. Select and rename the final columns
15. Remove duplicates on customer + document number + type + amount
16. Add days past due and ageing bucket against `pAsOfDate`
17. Set types and sort

## Checks

Row counts: 670 raw lines -> 510 document lines -> **497** after removing 13 duplicates.

Reconciliation: the report prints grand totals at the bottom of the raw file. The cleaned table adds up to exactly those numbers in all three currencies.

| Currency | Report grand total | Sum of cleaned table | Difference |
|---|---:|---:|---:|
| INR | 45,062,632.30 | 45,062,632.30 | 0.00 |
| USD | 77,562.59 | 77,562.59 | 0.00 |
| EUR | 29,887.14 | 29,887.14 | 0.00 |

Ageing as on 30 Sep 2026 (`AR_Aging_Summary`). USD and EUR are not converted:

| Bucket (days past due) | Items | INR | USD | EUR |
|---|---:|---:|---:|---:|
| Not due | 153 | 17,475,655.67 | 38,448.34 | 6,031.00 |
| 1-30 | 97 | 6,971,835.11 | 25,706.53 | 0.00 |
| 31-60 | 60 | 4,532,542.13 | 0.00 | 0.00 |
| 61-90 | 37 | 3,693,329.00 | 1,442.48 | 0.00 |
| 91-180 | 89 | 7,143,316.71 | 14,300.94 | 23,856.14 |
| 180+ | 61 | 5,245,953.68 | -2,335.70 | 0.00 |
| **Total** | **497** | **45,062,632.30** | **77,562.59** | **29,887.14** |

The *Aging_Summary* sheet in the workbook does the same with SUMIFS formulas on the cleaned sheet, plus ageing by customer.

## Assumptions

- Credit notes and on-account receipts are always negative. A positive number printed on one of these is treated as a print error (12 lines).
- A blank currency is taken as INR. Blank payment terms on an invoice use the customer's default terms from the master.
- A due date earlier than the invoice date is treated as a typo and rebuilt from doc date + terms.
- Credit notes, receipts and journals have no terms, so their due date is their document date.
- `IsDisputed` is a plain text match on "disp" in the remarks. It is a starting point, not a dispute register.
- Customers that are not in the master (17 lines, 2 customers) keep their name from the report in proper case and get a flag.
- No currency conversion. Totals are kept per currency.

## About the data

The customers, document numbers, amounts and people in this repo are made up for the example. Any resemblance to real companies is coincidental. The format of the raw file is modelled on a typical ERP open-items printout.
