// Holds a blob for WindowsText.Codeunit.al. A table of the app's own, so the test needs no
// dependency beyond Library Assert.
table 70010 "BC Linux Windows Text Blob"
{
    DataClassification = SystemMetadata;

    fields
    {
        field(1; Id; Integer) { }
        field(2; Data; Blob) { }
        field(3; Stamp; DateTime) { }
    }

    keys
    {
        key(PK; Id) { }
    }
}
