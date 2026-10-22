// Reads the table of WindowsText.Codeunit.al for the CSV test (issue #120).
query 70011 "BC Linux Windows Text Query"
{
    elements
    {
        dataitem(Row; "BC Linux Windows Text Blob")
        {
            column(Id; Id) { }
            column(Stamp; Stamp) { }
        }
    }
}
