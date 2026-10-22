// Regression guard for issue #122, item 5: a client-side Confirm on the websocket runner.
//
// A line entered in a part before the host record has its key inserts the host with a
// blank key. Typing the key then renames it, and because the line's field relates to the
// host BC asks the client "Your change might update related records, which can take a
// while. Do you want to continue?". The websocket runner answered that with a null
// result, NSClientCallback unboxed it to bool, and the session died with a
// NullReferenceException (on BC 27, where every test goes through that runner). It now
// answers with the request's default, as the hub does; a Windows container gives the same
// end state: the host keeps its blank key and the line its blank Document No.
//
// The objects live in this file because nothing else uses them.
table 70014 "BC Linux Rename Header"
{
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "No."; Code[20]) { }
        field(2; Name; Text[30]) { }
    }

    keys
    {
        key(PK; "No.") { Clustered = true; }
    }
}

table 70015 "BC Linux Rename Line"
{
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "Document No."; Code[20]) { TableRelation = "BC Linux Rename Header"; }
        field(2; "Line No."; Integer) { }
        field(3; Description; Text[30]) { }
        field(4; Quantity; Decimal) { }
    }

    keys
    {
        key(PK; "Document No.", "Line No.") { Clustered = true; }
    }
}

page 70016 "BC Linux Rename Lines"
{
    PageType = ListPart;
    SourceTable = "BC Linux Rename Line";
    AutoSplitKey = true;
    ApplicationArea = All;
    UsageCategory = None;

    layout
    {
        area(Content)
        {
            repeater(Rows)
            {
                field(Description; Rec.Description) { ApplicationArea = All; }
                field(Quantity; Rec.Quantity) { ApplicationArea = All; }
            }
        }
    }
}

page 70017 "BC Linux Rename Document"
{
    PageType = Document;
    SourceTable = "BC Linux Rename Header";
    ApplicationArea = All;
    UsageCategory = None;

    layout
    {
        area(Content)
        {
            group(General)
            {
                field("No."; Rec."No.") { ApplicationArea = All; }
                field(Name; Rec.Name) { ApplicationArea = All; }
            }
            part(Lines; "BC Linux Rename Lines")
            {
                ApplicationArea = All;
                SubPageLink = "Document No." = field("No.");
            }
        }
    }
}

codeunit 70018 "BC Linux Rename Confirm Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure KeyTypedAfterAPartLineKeepsTheSession()
    var
        Header: Record "BC Linux Rename Header";
        Line: Record "BC Linux Rename Line";
        Host: TestPage "BC Linux Rename Document";
    begin
        Line.DeleteAll();
        Header.DeleteAll();

        Host.OpenNew();
        Host.Lines.New();
        Host.Lines.Description.SetValue('first');
        Host.Lines.Quantity.SetValue(3);
        Host."No.".SetValue('D1');
        Host.Name.SetValue('Doc one');
        Host.Close();

        LibraryAssert.AreEqual(1, Header.Count(), 'headers');
        Header.FindFirst();
        LibraryAssert.AreEqual('', Header."No.", 'header key');
        LibraryAssert.AreEqual('Doc one', Header.Name, 'header name');
        LibraryAssert.AreEqual(1, Line.Count(), 'lines');
        Line.FindFirst();
        LibraryAssert.AreEqual('', Line."Document No.", 'line Document No.');
        LibraryAssert.AreEqual(3, Line.Quantity, 'line quantity');
    end;
}
