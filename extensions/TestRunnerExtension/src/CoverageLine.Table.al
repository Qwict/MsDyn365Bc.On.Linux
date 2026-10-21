/// <summary>
/// The executable lines of the code under test, one record each, as Test Runner
/// Extension 3.x stored them. Nothing uses it any more: the "Coverage Recorder" keeps
/// the run in one report blob. Obsolete rather than removed because tenants that had
/// it upgrade in place, and dropping a table is a destructive schema change.
/// </summary>
table 99904 "Coverage Line"
{
    DataClassification = SystemMetadata;
    ReplicateData = false;
    ObsoleteState = Pending;
    ObsoleteReason = 'Replaced by the report blob in "Coverage Setup"; no longer read or written.';
    ObsoleteTag = '4.0';

    fields
    {
        field(1; "Object Type"; Text[30]) { }
        field(2; "Object ID"; Integer) { }
        field(3; "Line No."; Integer) { }
        field(4; Hits; Integer) { }
    }

    keys
    {
        key(PK; "Object Type", "Object ID", "Line No.") { Clustered = true; }
    }
}
