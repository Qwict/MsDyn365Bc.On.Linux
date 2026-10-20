/// <summary>
/// Whether the next test run records code coverage, which run that is, and what it
/// recorded. One record. startCoverage enables it, starts a new generation and
/// empties Coverage; stopCoverage disables it. The "Coverage Recorder" in the test
/// session follows it and stores the run's lines in Coverage.
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
        // What the recorder's writes of the current run cost, to tell its share of a run apart.
        field(10; "Writes"; Integer) { }
        field(11; "Write Time"; Duration) { }
        field(12; "Last Write Lines Read"; Integer) { }
        field(13; "Last Write Lines Stored"; Integer) { }
        field(14; "Last Write Base Lines"; Integer) { }
        field(15; "Last Write At"; DateTime) { }
        // The run's coverage as CSV lines object_type,object_id,line_no,hits (UTF-8, no header).
        field(20; Coverage; Blob) { }
    }

    keys
    {
        key(PK; "Primary Key") { Clustered = true; }
    }
}
