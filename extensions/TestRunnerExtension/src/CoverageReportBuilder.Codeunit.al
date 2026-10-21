/// <summary>
/// Builds the stored coverage report as text: one record per line, comma separated, with
/// a leading record type.
///
///   M,key,value                               run metadata
///   A,app id,name,publisher,version           an app under test
///   O,type,id,app id,measured                 an object in scope; measured 0 = BC has no lines for it
///   L,type,id,line,hits,partial               an executable (Code) line
///   F,type,id,line,executed,signature         a trigger or procedure
///
/// The type is the AL keyword. The signature is the last field, because it may contain
/// commas; it is quoted CSV-style then. Numbers, GUIDs and dates are written in the
/// invariant format, so the text reads the same whatever the server's language.
/// docs/CODE-COVERAGE.md describes the format and what each record means.
/// </summary>
codeunit 99913 "Coverage Report Builder"
{
    var
        Body: TextBuilder;
        // Object keys that have at least one line.
        MeasuredObjects: Dictionary of [Text, Boolean];
        // The last object marked, with its trailing comma: rows arrive object by object, so
        // most lines need no lookup.
        LastObjectPrefix: Text;
        WriteCount: Integer;
        WriteMs: BigInteger;
        LastWriteMs: BigInteger;
        IncludeMs: BigInteger;
        InventoryLines: Integer;
        IsInventoryWrite: Boolean;
        RunGeneration: Integer;
        RunComplete: Boolean;
        RunStartedAt: DateTime;
        LineCount: Integer;
        CoveredLineCount: Integer;
        ObjectCount: Integer;
        UnmeasuredObjectCount: Integer;

    procedure Initialize(Generation: Integer; Complete: Boolean; StartedAt: DateTime)
    begin
        Clear(Body);
        Clear(MeasuredObjects);
        LastObjectPrefix := '';
        RunGeneration := Generation;
        RunComplete := Complete;
        RunStartedAt := StartedAt;
        LineCount := 0;
        CoveredLineCount := 0;
        ObjectCount := 0;
        UnmeasuredObjectCount := 0;
    end;

    /// <summary>
    /// What the recorder's earlier writes of the run cost, for the report's metadata. The
    /// write being built is not in it: its cost is only known once it is stored. Set
    /// InventoryWrite on the first write of a session, whose line count is the inventory.
    /// </summary>
    procedure SetDiagnostics(Writes: Integer; TotalWriteMs: BigInteger; LastMs: BigInteger; IncludeStepMs: BigInteger; Inventory: Integer; InventoryWrite: Boolean)
    begin
        WriteCount := Writes;
        WriteMs := TotalWriteMs;
        LastWriteMs := LastMs;
        IncludeMs := IncludeStepMs;
        InventoryLines := Inventory;
        IsInventoryWrite := InventoryWrite;
    end;

    /// <summary>
    /// Adds a Code line. LineKey is "type,id,line"; its object is everything before the
    /// last comma.
    /// </summary>
    procedure AddLine(LineKey: Text; Hits: Integer; Partial: Boolean)
    begin
        Body.AppendLine('L,' + LineKey + ',' + Format(Hits, 0, 9) + ',' + Flag(Partial));
        MarkMeasured(LineKey);
        LineCount += 1;
        if Hits > 0 then
            CoveredLineCount += 1;
    end;

    /// <summary>
    /// Adds a trigger or procedure; the signature is quoted here. BC puts a notice about the
    /// ShowMyCode manifest property in place of the source of an app that hides it; that
    /// is not a signature, and shipping it with every function would only bloat the report.
    /// </summary>
    procedure AddFunction(LineKey: Text; Executed: Boolean; Signature: Text)
    begin
        if not IsDeclaration(Signature) then
            Signature := '';
        AddStoredFunction(LineKey, Executed, Quote(Signature));
    end;

    /// <summary>
    /// Adds a trigger or procedure whose signature is already quoted, as read back from
    /// the stored report.
    /// </summary>
    procedure AddStoredFunction(LineKey: Text; Executed: Boolean; QuotedSignature: Text)
    begin
        Body.AppendLine('F,' + LineKey + ',' + Flag(Executed) + ',' + QuotedSignature);
        MarkMeasured(LineKey);
    end;

    /// <summary>
    /// The whole report: metadata, apps and objects from the scope, then the lines added.
    /// An object of the scope with no line is listed as unmeasured; the legacy scope has
    /// no list of objects, so it lists those that had lines.
    /// </summary>
    procedure ToText(var Scope: Codeunit "Coverage Scope"): Text
    var
        Report: TextBuilder;
    begin
        AppendMetadata(Report, Scope);
        AppendApps(Report, Scope);
        AppendObjects(Report, Scope);
        Report.Append(Body.ToText());
        exit(Report.ToText());
    end;

    procedure GetCounts(var Objects: Integer; var Lines: Integer; var CoveredLines: Integer; var UnmeasuredObjects: Integer)
    begin
        Objects := ObjectCount;
        Lines := LineCount;
        CoveredLines := CoveredLineCount;
        UnmeasuredObjects := UnmeasuredObjectCount;
    end;

    procedure GetLineCount(): Integer
    begin
        exit(LineCount);
    end;

    /// <summary>
    /// A field with a comma or a quote in it, quoted CSV-style (quotes doubled). Line
    /// breaks become spaces: the report is one record per line.
    /// </summary>
    procedure Quote(Value: Text): Text
    begin
        Value := Value.Trim().Replace(ControlChar(13), ' ').Replace(ControlChar(10), ' ');
        if Value.Contains(',') or Value.Contains('"') then
            exit('"' + Value.Replace('"', '""') + '"');
        exit(Value);
    end;

    local procedure AppendMetadata(var Report: TextBuilder; var Scope: Codeunit "Coverage Scope")
    var
        CoverageSetup: Record "Coverage Setup";
        IgnoredAppIds: List of [Text];
        DroppedAppIds: List of [Text];
        Mode: Text;
        Sessions: Text;
    begin
        Sessions := 'test';
        if CoverageSetup.Get() then
            if CoverageSetup."Multi Session" then
                Sessions := 'all';
        Mode := 'apps';
        if Scope.IsLegacy() then
            Mode := 'legacy';
        Report.AppendLine('M,version,2');
        Report.AppendLine('M,generation,' + Format(RunGeneration, 0, 9));
        Report.AppendLine('M,complete,' + Flag(RunComplete));
        Report.AppendLine('M,mode,' + Mode);
        Report.AppendLine('M,sessions,' + Sessions);
        Report.AppendLine('M,started,' + Format(RunStartedAt, 0, 9));
        Report.AppendLine('M,written,' + Format(CurrentDateTime(), 0, 9));
        // The cost of the recorder's earlier writes, see SetDiagnostics.
        Report.AppendLine('M,writes,' + Format(WriteCount, 0, 9));
        Report.AppendLine('M,write_ms,' + Format(WriteMs, 0, 9));
        Report.AppendLine('M,last_write_ms,' + Format(LastWriteMs, 0, 9));
        Report.AppendLine('M,include_ms,' + Format(IncludeMs, 0, 9));
        if IsInventoryWrite then
            Report.AppendLine('M,inventory_lines,' + Format(LineCount, 0, 9))
        else
            Report.AppendLine('M,inventory_lines,' + Format(InventoryLines, 0, 9));
        IgnoredAppIds := Scope.GetIgnoredAppIds();
        if IgnoredAppIds.Count() > 0 then
            // Semicolons: a comma would split the value into fields.
            Report.AppendLine('M,ignored,' + Quote(JoinText(IgnoredAppIds, ';')));
        DroppedAppIds := Scope.GetDroppedAppIds();
        if DroppedAppIds.Count() > 0 then
            // Apps left out of the scope because another app in it depends on them.
            Report.AppendLine('M,dependency_dropped,' + Quote(JoinText(DroppedAppIds, ';')));
    end;

    local procedure AppendApps(var Report: TextBuilder; var Scope: Codeunit "Coverage Scope")
    var
        TempScopeApp: Record "Coverage Scope App" temporary;
    begin
        Scope.GetApps(TempScopeApp);
        if TempScopeApp.FindSet() then
            repeat
                Report.AppendLine('A,' + Format(TempScopeApp."App ID", 0, 4).ToLower() + ',' + Quote(TempScopeApp.Name) + ',' + Quote(TempScopeApp.Publisher) + ',' + Quote(TempScopeApp.Version));
            until TempScopeApp.Next() = 0;
    end;

    local procedure AppendObjects(var Report: TextBuilder; var Scope: Codeunit "Coverage Scope")
    var
        ObjectKey: Text;
        ObjectKeys: List of [Text];
    begin
        if Scope.IsLegacy() then
            ObjectKeys := MeasuredObjects.Keys()
        else
            ObjectKeys := Scope.GetObjectKeys();
        foreach ObjectKey in ObjectKeys do begin
            Report.AppendLine('O,' + ObjectKey + ',' + Scope.GetAppId(ObjectKey) + ',' + Flag(MeasuredObjects.ContainsKey(ObjectKey)));
            ObjectCount += 1;
            if not MeasuredObjects.ContainsKey(ObjectKey) then
                UnmeasuredObjectCount += 1;
        end;
    end;

    local procedure MarkMeasured(LineKey: Text)
    var
        ObjectKey: Text;
    begin
        // The comma ends the object key, so "Codeunit,5," never matches "Codeunit,50,".
        if (LastObjectPrefix <> '') and LineKey.StartsWith(LastObjectPrefix) then
            exit;
        ObjectKey := LineKey.Substring(1, LineKey.LastIndexOf(',') - 1);
        if not MeasuredObjects.ContainsKey(ObjectKey) then
            MeasuredObjects.Add(ObjectKey, true);
        LastObjectPrefix := ObjectKey + ',';
    end;

    /// <summary>
    /// Whether a function row's text is a declaration: procedure or trigger, after an
    /// optional access modifier, in any case.
    /// </summary>
    local procedure IsDeclaration(Signature: Text): Boolean
    var
        Declaration: Text;
    begin
        Declaration := Signature.TrimStart().ToLower();
        if Declaration.StartsWith('local ') then
            Declaration := Declaration.Substring(7).TrimStart()
        else
            if Declaration.StartsWith('internal ') then
                Declaration := Declaration.Substring(10).TrimStart()
            else
                if Declaration.StartsWith('protected ') then
                    Declaration := Declaration.Substring(11).TrimStart();
        exit(StartsWithWord(Declaration, 'procedure') or StartsWithWord(Declaration, 'trigger'));
    end;

    local procedure StartsWithWord(Value: Text; Word: Text): Boolean
    var
        Following: Text;
    begin
        if not Value.StartsWith(Word) then
            exit(false);
        if StrLen(Value) = StrLen(Word) then
            exit(true);
        Following := Value.Substring(StrLen(Word) + 1, 1);
        exit((Following = ' ') or (Following = '(') or (Following = ControlChar(9)));
    end;

    local procedure ControlChar(Code: Integer): Text
    var
        Character: Text[1];
    begin
        Character[1] := Code;
        exit(Character);
    end;

    local procedure Flag(Value: Boolean): Text
    begin
        if Value then
            exit('1');
        exit('0');
    end;

    local procedure JoinText(Values: List of [Text]; Separator: Text): Text
    var
        Joined: TextBuilder;
        Value: Text;
    begin
        foreach Value in Values do begin
            if Joined.Length() > 0 then
                Joined.Append(Separator);
            Joined.Append(Value);
        end;
        exit(Joined.ToText());
    end;
}
