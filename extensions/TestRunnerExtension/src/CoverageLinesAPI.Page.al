/// <summary>
/// The code lines the last coverage run saw, with their hit counts. A line with 0
/// hits is a line in a loaded object that no test ran. See "Coverage Line Collector".
/// </summary>
page 99904 "Coverage Lines API"
{
    PageType = API;
    Caption = 'Code Coverage Lines';
    APIPublisher = 'custom';
    APIGroup = 'automation';
    APIVersion = 'v1.0';
    EntityName = 'codeCoverageLine';
    EntitySetName = 'codeCoverageLines';
    SourceTable = "Coverage Line";
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    DataAccessIntent = ReadOnly;

    layout
    {
        area(content)
        {
            repeater(Lines)
            {
                field(objectType; Rec."Object Type") { }
                field(objectId; Rec."Object ID") { }
                field(lineNo; Rec."Line No.") { }
                field(hits; Rec.Hits) { }
            }
        }
    }
}
