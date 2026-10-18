/// <summary>
/// The code lines the last coverage recording saw (StartCoverage / StopCoverage on
/// codeunitRunRequests), with their hit counts.
///
/// Only Code lines count towards coverage: object, trigger and empty lines are not
/// executable. Only partner object ranges are listed (per-tenant 50000..99999 and
/// ISV 1000000..74999999), without this extension's own 99900..99999: Microsoft's
/// apps, the test framework and the runner are not what a caller is testing.
/// A line with 0 hits is a line in a loaded object that no test ran.
/// </summary>
page 99904 "Code Coverage Lines API"
{
    PageType = API;
    Caption = 'Code Coverage Lines';
    APIPublisher = 'custom';
    APIGroup = 'automation';
    APIVersion = 'v1.0';
    EntityName = 'codeCoverageLine';
    EntitySetName = 'codeCoverageLines';
    SourceTable = System.Tooling."Code Coverage";
    SourceTableView = where("Line Type" = const(Code), "Object ID" = filter(50000 .. 99899 | 1000000 .. 74999999));
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
                field(hits; Rec."No. of Hits") { }
            }
        }
    }
}
