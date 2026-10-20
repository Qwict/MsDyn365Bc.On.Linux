/// <summary>
/// The last coverage run's lines in one response: csv holds one line
/// object_type,object_id,line_no,hits per executable line of the loaded partner objects
/// (no header; 0 hits = no test ran it). Reading 120,000 lines through codeCoverageLines
/// takes one request per page and one record per line; this is one request.
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
            }
        }
    }

    var
        Csv: Text;

    trigger OnAfterGetRecord()
    var
        CoverageStore: Codeunit "Coverage Store";
    begin
        Csv := CoverageStore.Read();
    end;
}
