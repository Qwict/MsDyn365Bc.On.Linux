/// <summary>
/// Whether the next test run records code coverage, which run that is, what it measures
/// and what it recorded. One record. startCoverage and startCoverageForApps enable it,
/// start a new generation and empty Report; stopCoverage disables it. The "Coverage
/// Recorder" in the test session follows it and stores the run's report in Report.
/// </summary>
table 99905 "Coverage Setup"
{
    Caption = 'Coverage Setup';
    DataClassification = SystemMetadata;
    ReplicateData = false;

    fields
    {
        field(1; "Primary Key"; Code[10]) { Caption = 'Primary Key'; }
        field(2; Enabled; Boolean) { Caption = 'Enabled'; }
        field(3; Generation; Integer) { Caption = 'Generation'; }
        // Whether other sessions' hits are recorded too; startCoverage (no scope) keeps the 3.x behaviour, off.
        field(4; "Multi Session"; Boolean)
        {
            Caption = 'Multi Session';
            InitValue = true;
        }
        // Whether the run measures the apps in Scope App Ids; false = the legacy partner ID ranges.
        field(5; Scoped; Boolean) { Caption = 'Scoped'; }
        // The app IDs startCoverageForApps was given, comma separated, as given.
        field(6; "Scope App Ids"; Text[2048]) { Caption = 'Scope App Ids'; }
        field(7; "Started At"; DateTime) { Caption = 'Started At'; }
        // Whether the last write was the one after the last test codeunit.
        field(8; Complete; Boolean) { Caption = 'Complete'; }
        // What the recorder's writes of the current run cost, to tell its share of a run apart.
        field(10; "Writes"; Integer) { Caption = 'Writes'; }
        field(11; "Write Time"; Duration) { Caption = 'Write Time'; }
        field(12; "Last Write Lines Read"; Integer) { Caption = 'Last Write Lines Read'; }
        field(13; "Last Write Lines Stored"; Integer) { Caption = 'Last Write Lines Stored'; }
        field(14; "Last Write Base Lines"; Integer) { Caption = 'Last Write Base Lines'; }
        field(15; "Last Write At"; DateTime) { Caption = 'Last Write At'; }
        // What the report holds, to answer without parsing it.
        field(16; Objects; Integer) { Caption = 'Objects'; }
        field(17; Lines; Integer) { Caption = 'Lines'; }
        field(18; "Covered Lines"; Integer) { Caption = 'Covered Lines'; }
        field(19; "Unmeasured Objects"; Integer) { Caption = 'Unmeasured Objects'; }
        // The 3.x CSV of the run. Replaced by Report; kept because dropping a field is a destructive schema change.
        field(20; Coverage; Blob)
        {
            Caption = 'Coverage';
            ObsoleteState = Pending;
            ObsoleteReason = 'Replaced by Report, which holds the report of "Coverage Report Builder".';
            ObsoleteTag = '4.0';
        }
        // The run's report as UTF-8 text, see "Coverage Report Builder".
        field(21; Report; Blob) { Caption = 'Report'; }
    }

    keys
    {
        key(PK; "Primary Key") { Clustered = true; }
    }
}
