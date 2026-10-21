/// <summary>
/// An app a coverage run measures, as "Coverage Scope" resolved it from the installed
/// apps. Temporary: it lives as long as the scope codeunit that fills it.
/// </summary>
table 99915 "Coverage Scope App"
{
    Caption = 'Coverage Scope App';
    DataClassification = SystemMetadata;
    TableType = Temporary;

    fields
    {
        field(1; "App ID"; Guid) { Caption = 'App ID'; }
        field(2; "Package ID"; Guid) { Caption = 'Package ID'; }
        field(3; Name; Text[250]) { Caption = 'Name'; }
        field(4; Publisher; Text[250]) { Caption = 'Publisher'; }
        field(5; Version; Text[50]) { Caption = 'Version'; }
    }

    keys
    {
        key(PK; "App ID") { Clustered = true; }
    }
}
