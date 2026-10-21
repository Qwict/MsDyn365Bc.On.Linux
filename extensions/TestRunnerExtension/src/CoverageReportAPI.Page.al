/// <summary>
/// The last coverage run's report in one response.
///
/// report is the v2 text of "Coverage Report Builder" (see docs/CODE-COVERAGE.md): the
/// run's metadata, apps, objects, lines and functions. complete says the run reached its
/// final write; the counts are what the report holds: objects in scope, executable lines,
/// the lines with at least one hit, and objects BC has no lines for (extensions no test
/// ran). csv is the 3.x format for older callers, object_type,object_id,line_no,hits per
/// executable line, no header, cut out of the report.
/// Reading 120,000 lines through one record each takes a request per page; this is one.
/// </summary>
page 99907 "Coverage Report API"
{
    PageType = API;
    Caption = 'Code Coverage Report';
    APIPublisher = 'custom';
    APIGroup = 'automation';
    APIVersion = 'v1.0';
    EntityName = 'coverageReport';
    EntitySetName = 'coverageReports';
    SourceTable = "Coverage Setup";
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    DataAccessIntent = ReadOnly;

    layout
    {
        area(content)
        {
            repeater(Reports)
            {
                field(generation; Rec.Generation) { }
                field(csv; Csv) { }
                field(report; ReportText) { }
                field(complete; Rec.Complete) { }
                field(objects; Rec.Objects) { }
                field(lines; Rec.Lines) { }
                field(coveredLines; Rec."Covered Lines") { }
                field(unmeasuredObjects; Rec."Unmeasured Objects") { }
            }
        }
    }

    var
        Csv: Text;
        ReportText: Text;

    trigger OnAfterGetRecord()
    var
        CoverageStore: Codeunit "Coverage Store";
    begin
        ReportText := CoverageStore.ReadReport();
        Csv := CoverageStore.CsvFromReport(ReportText);
    end;
}
