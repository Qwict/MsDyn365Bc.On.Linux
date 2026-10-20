/// <summary>
/// Whether the next test run records code coverage, and which run that is. One
/// record. startCoverage enables it and starts a new generation; stopCoverage
/// disables it. The "Coverage Recorder" in the test session follows it.
/// </summary>
table 99905 "Coverage Setup"
{
    DataClassification = SystemMetadata;
    ReplicateData = false;

    fields
    {
        field(1; "Primary Key"; Code[10]) { }
        field(2; Enabled; Boolean) { }
        field(3; Generation; Integer) { }
    }

    keys
    {
        key(PK; "Primary Key") { Clustered = true; }
    }
}
