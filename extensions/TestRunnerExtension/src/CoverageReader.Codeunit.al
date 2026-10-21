/// <summary>
/// Reads the platform's Code Coverage table for the scope and hands the lines to the
/// "Coverage Report Builder", merged with what an earlier session of the same run stored.
///
/// The read is limited to the scope's Object IDs, which the table is indexed on; a read on
/// Line Type alone scans every object of the database (over a minute on a Base
/// Application). Rows of objects the ID ranges let through but the scope does not hold are
/// dropped by an exact lookup.
///
/// Trigger and function rows say whether a method ran only through Method Id, which is -1
/// until it does. That is what "executed" means here; a method whose body has no Code line
/// (an empty procedure) still counts as executed once called.
/// </summary>
codeunit 99916 "Coverage Reader"
{
    Permissions = tabledata System.Tooling."Code Coverage" = r;

    var
        Store: Codeunit "Coverage Store";
        ObjectType: Codeunit "Coverage Object Type";
        // Line key ("type,id,line") to "hits,partial" as stored by an earlier session of the run.
        BaseLines: Dictionary of [Text, Text];
        // Line key to "executed,signature" as stored.
        BaseFunctions: Dictionary of [Text, Text];

    /// <summary>
    /// Loads what the run has stored so far, which this session's hits are added to. Empty
    /// in the first session of a run.
    /// </summary>
    procedure LoadBase()
    begin
        Store.LoadBase(BaseLines, BaseFunctions);
    end;

    procedure BaseLineCount(): Integer
    begin
        exit(BaseLines.Count());
    end;

    /// <summary>
    /// Adds every line and function of the scope to the Builder: this session's rows plus
    /// the stored ones this session did not see. Returns the number of rows read.
    /// </summary>
    procedure ReadInto(var Scope: Codeunit "Coverage Scope"; var Builder: Codeunit "Coverage Report Builder"): Integer
    var
        CodeCoverage: Record System.Tooling."Code Coverage";
        SeenLines: Dictionary of [Text, Boolean];
        SeenFunctions: Dictionary of [Text, Boolean];
        RowsRead: Integer;
        ObjectIdFilter: Text;
    begin
        ObjectIdFilter := Scope.ObjectIdFilter();
        if ObjectIdFilter <> '' then begin
            CodeCoverageRefresh();
            CodeCoverage.SetFilter("Object ID", ObjectIdFilter);
            CodeCoverage.SetFilter("Line Type", '%1|%2', CodeCoverage."Line Type"::Code, CodeCoverage."Line Type"::"Trigger/Function");
            if CodeCoverage.FindSet() then
                repeat
                    RowsRead += 1;
                    AddRow(CodeCoverage, Scope, Builder, SeenLines, SeenFunctions);
                until CodeCoverage.Next() = 0;
        end;
        AddStoredOnly(Builder, SeenLines, SeenFunctions);
        exit(RowsRead);
    end;

    local procedure AddRow(var CodeCoverage: Record System.Tooling."Code Coverage"; var Scope: Codeunit "Coverage Scope"; var Builder: Codeunit "Coverage Report Builder"; var SeenLines: Dictionary of [Text, Boolean]; var SeenFunctions: Dictionary of [Text, Boolean])
    var
        Ordinal: Integer;
        ObjectKey: Text;
        LineKey: Text;
    begin
        Ordinal := CodeCoverage."Object Type";
        ObjectKey := ObjectType.ObjectKey(Ordinal, CodeCoverage."Object ID");
        if not Scope.Contains(ObjectKey) then
            exit;
        LineKey := ObjectKey + ',' + Format(CodeCoverage."Line No.", 0, 9);
        if CodeCoverage."Line Type" = CodeCoverage."Line Type"::Code then begin
            AddCodeLine(CodeCoverage, LineKey, Builder);
            SeenLines.Set(LineKey, true);
        end else begin
            AddFunction(CodeCoverage, LineKey, Builder);
            SeenFunctions.Set(LineKey, true);
        end;
    end;

    local procedure AddCodeLine(var CodeCoverage: Record System.Tooling."Code Coverage"; LineKey: Text; var Builder: Codeunit "Coverage Report Builder")
    var
        Hits: Integer;
        Partial: Boolean;
        StoredValue: Text;
    begin
        Hits := CodeCoverage."No. of Hits";
        Partial := CodeCoverage."Code Coverage Status" = CodeCoverage."Code Coverage Status"::PartiallyCovered;
        if BaseLines.Get(LineKey, StoredValue) then
            MergeStoredLine(StoredValue, Hits, Partial);
        Builder.AddLine(LineKey, Hits, Partial);
    end;

    local procedure AddFunction(var CodeCoverage: Record System.Tooling."Code Coverage"; LineKey: Text; var Builder: Codeunit "Coverage Report Builder")
    var
        Executed: Boolean;
        StoredValue: Text;
    begin
        Executed := CodeCoverage."Method Id" <> -1;
        if BaseFunctions.Get(LineKey, StoredValue) then
            Executed := Executed or StoredValue.StartsWith('1');
        Builder.AddFunction(LineKey, Executed, CodeCoverage.Line);
    end;

    /// <summary>
    /// Adds the lines and functions an earlier session stored and this one has not seen,
    /// so a replaced session does not lose what its predecessor recorded.
    /// </summary>
    local procedure AddStoredOnly(var Builder: Codeunit "Coverage Report Builder"; var SeenLines: Dictionary of [Text, Boolean]; var SeenFunctions: Dictionary of [Text, Boolean])
    var
        LineKey: Text;
        Hits: Integer;
        Partial: Boolean;
        StoredValue: Text;
    begin
        foreach LineKey in BaseLines.Keys() do
            if not SeenLines.ContainsKey(LineKey) then begin
                Hits := 0;
                Partial := false;
                MergeStoredLine(BaseLines.Get(LineKey), Hits, Partial);
                Builder.AddLine(LineKey, Hits, Partial);
            end;
        foreach LineKey in BaseFunctions.Keys() do
            if not SeenFunctions.ContainsKey(LineKey) then begin
                StoredValue := BaseFunctions.Get(LineKey);
                Builder.AddStoredFunction(LineKey, StoredValue.StartsWith('1'), StoredValue.Substring(3));
            end;
    end;

    /// <summary>
    /// Adds a stored line ("hits,partial") to this session's hits. A merged line is partial
    /// only if every session that ran it ran it partially.
    /// </summary>
    local procedure MergeStoredLine(StoredValue: Text; var Hits: Integer; var Partial: Boolean)
    var
        Parts: List of [Text];
        StoredHits: Integer;
        StoredPartial: Boolean;
    begin
        Parts := StoredValue.Split(',');
        if Parts.Count() <> 2 then
            exit;
        if not Evaluate(StoredHits, Parts.Get(1), 9) then
            exit;
        StoredPartial := Parts.Get(2) = '1';
        Partial := ((Hits = 0) or Partial) and ((StoredHits = 0) or StoredPartial) and (Hits + StoredHits > 0);
        Hits += StoredHits;
    end;
}
