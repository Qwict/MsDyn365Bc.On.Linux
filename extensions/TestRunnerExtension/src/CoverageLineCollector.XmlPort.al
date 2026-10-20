/// <summary>
/// The exporter Test Runner Extension 3.3 put on the DEFAULT suite (CC Exporter ID)
/// for Microsoft's Test Runner to call after each test codeunit. Coverage is now
/// recorded by the "Coverage Recorder" and the suite's CC fields stay off, but a
/// suite a 3.3 run left configured would still call this once per codeunit, so it
/// stays, exporting nothing, until the next setupSuite or startCoverage clears them.
/// </summary>
xmlport 99904 "Coverage Line Collector"
{
    Direction = Export;
    Format = VariableText;
    FieldDelimiter = '';
    FieldSeparator = ',';
    TextEncoding = UTF16;

    schema
    {
        textelement(Lines)
        {
            tableelement(Coverage; System.Tooling."Code Coverage")
            {
                fieldelement(ObjectID; Coverage."Object ID") { }
            }
        }
    }

    trigger OnPreXmlPort()
    begin
        Coverage.SetRange("Object ID", -1);
    end;
}
