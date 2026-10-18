/// <summary>
/// The exporter Microsoft's Test Runner calls after each test codeunit (CC Exporter
/// ID on the DEFAULT suite), in the test session, right after refreshing that
/// session's Code Coverage table.
///
/// The runner hands it only covered lines, and the table it saves to is internal to
/// the Test Runner app. So this ignores the record it is given: it reads the whole
/// Code Coverage table itself — 0-hit lines included, which is what makes a
/// percentage possible — and keeps every Code line of the partner objects
/// (per-tenant 50000..99899, ISV 1000000..74999999; not this extension's own
/// 99900..99999) in "Coverage Line", with the highest hit count seen. It writes
/// nothing to the runner's own result.
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
    var
        CodeCoverage: Record System.Tooling."Code Coverage";
        CoverageLine: Record "Coverage Line";
    begin
        CodeCoverage.SetRange("Line Type", CodeCoverage."Line Type"::Code);
        CodeCoverage.SetFilter("Object ID", '50000..99899|1000000..74999999');
        if CodeCoverage.FindSet() then
            repeat
                if CoverageLine.Get(Format(CodeCoverage."Object Type"), CodeCoverage."Object ID", CodeCoverage."Line No.") then begin
                    if CodeCoverage."No. of Hits" > CoverageLine.Hits then begin
                        CoverageLine.Hits := CodeCoverage."No. of Hits";
                        CoverageLine.Modify();
                    end;
                end else begin
                    CoverageLine.Init();
                    CoverageLine."Object Type" := CopyStr(Format(CodeCoverage."Object Type"), 1, MaxStrLen(CoverageLine."Object Type"));
                    CoverageLine."Object ID" := CodeCoverage."Object ID";
                    CoverageLine."Line No." := CodeCoverage."Line No.";
                    CoverageLine.Hits := CodeCoverage."No. of Hits";
                    CoverageLine.Insert();
                end;
            until CodeCoverage.Next() = 0;
        // Export nothing: the result is in "Coverage Line".
        Coverage.SetRange("Object ID", -1);
    end;
}
