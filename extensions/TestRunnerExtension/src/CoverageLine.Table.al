/// <summary>
/// The executable lines of the code under test and how often the last coverage run
/// executed each one. Filled by the "Coverage Line Collector" exporter, read through
/// the codeCoverageLines API page, emptied by startCoverage.
/// </summary>
table 99904 "Coverage Line"
{
    DataClassification = SystemMetadata;
    ReplicateData = false;

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
