/// <summary>
/// Records the code coverage of a whole test run in the session that runs the tests
/// and writes it to "Coverage Line".
///
/// Microsoft's Test Runner can record coverage itself, but only by starting and
/// stopping the platform's coverage log around every test codeunit and handing an
/// exporter the session's whole Code Coverage table each time. Merging that table
/// into "Coverage Line" once per codeunit — about 120,000 lines of a large app, one
/// record at a time — made a covered run three to eight times slower than a plain
/// one, nearly all of it between the codeunits.
///
/// This recorder starts the log once, before the first test codeunit of a run, and
/// leaves it running, so the platform adds up the hits of the whole run. After the
/// last codeunit it reads the Code Coverage table once and writes every Code line of
/// the partner objects (per-tenant 50000..99899, ISV 1000000..74999999; not this
/// extension's own 99900..99999), 0-hit lines included, which is what makes a
/// percentage possible. In between, at most once per checkpoint interval, it writes
/// only the covered lines whose hits changed, so a session that dies mid-run loses
/// at most that interval.
///
/// A run is one startCoverage: a generation of "Coverage Setup". Another session in
/// the same run — the runner reconnected after a session died — continues from what
/// "Coverage Line" already holds and adds its own hits to it.
/// </summary>
codeunit 99910 "Coverage Recorder"
{
    SingleInstance = true;
    Permissions = tabledata "Coverage Line" = rimd,
                  tabledata "Coverage Setup" = r,
                  tabledata System.TestTools.TestRunner."Test Method Line" = r;

    var
        // Hits per line as "Coverage Line" holds them.
        Written: Dictionary of [Text, Integer];
        // Hits per line from before the running log started, which its own hits add to.
        SegmentBase: Dictionary of [Text, Integer];
        Recording: Boolean;
        RunGeneration: Integer;
        LastWrite: DateTime;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::System.TestTools.TestRunner."Test Runner - Mgt", 'OnBeforeCodeunitRun', '', false, false)]
    local procedure OnBeforeCodeunitRun(var TestMethodLine: Record System.TestTools.TestRunner."Test Method Line")
    var
        CoverageSetup: Record "Coverage Setup";
    begin
        if not CoverageSetup.Get() then
            CoverageSetup.Init();
        if not CoverageSetup.Enabled then begin
            StopLog();
            exit;
        end;
        if Recording and (RunGeneration = CoverageSetup.Generation) then
            exit;
        StartLog(CoverageSetup.Generation);
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::System.TestTools.TestRunner."Test Runner - Mgt", 'OnAfterCodeunitRun', '', false, false)]
    local procedure OnAfterCodeunitRun(var TestMethodLine: Record System.TestTools.TestRunner."Test Method Line")
    begin
        if not Recording then
            exit;
        if IsLastCodeunit(TestMethodLine) then begin
            Write(true);
            StopLog();
        end else
            if CurrentDateTime() - LastWrite >= CheckpointInterval() then
                Write(false);
    end;

    local procedure StartLog(Generation: Integer)
    begin
        // Starting the log clears the session's hits, so they count from here on top of SegmentBase.
        StopLog();
        if RunGeneration <> Generation then begin
            Clear(Written);
            LoadWritten();
        end;
        Copy(Written, SegmentBase);
        System.CodeCoverageLog(true, false);
        Recording := true;
        RunGeneration := Generation;
        LastWrite := CurrentDateTime();
    end;

    local procedure StopLog()
    begin
        if not Recording then
            exit;
        System.CodeCoverageLog(false, false);
        Recording := false;
    end;

    /// <summary>
    /// Brings "Coverage Line" up to the running log. Complete writes every Code line
    /// of the loaded partner objects; a checkpoint only the covered ones. Both insert
    /// the lines it does not have yet and update the ones whose hits changed.
    /// </summary>
    local procedure Write(Complete: Boolean)
    var
        CodeCoverage: Record System.Tooling."Code Coverage";
        CoverageLine: Record "Coverage Line";
        TempNewLine: Record "Coverage Line" temporary;
        TempChangedLine: Record "Coverage Line" temporary;
        LineKey: Text;
        Hits: Integer;
        Stored: Integer;
    begin
        System.CodeCoverageRefresh();
        CodeCoverage.SetRange("Line Type", CodeCoverage."Line Type"::Code);
        CodeCoverage.SetFilter("Object ID", '50000..99899|1000000..74999999');
        if not Complete then
            CodeCoverage.SetFilter("No. of Hits", '>0');
        // Read everything first: inserts stay buffered only while nothing reads in between.
        if CodeCoverage.FindSet() then
            repeat
                LineKey := Format(CodeCoverage."Object Type") + ':' + Format(CodeCoverage."Object ID", 0, 9) + ':' + Format(CodeCoverage."Line No.", 0, 9);
                if not SegmentBase.Get(LineKey, Hits) then
                    Hits := 0;
                Hits += CodeCoverage."No. of Hits";
                if Written.Get(LineKey, Stored) then begin
                    if Hits <> Stored then begin
                        Written.Set(LineKey, Hits);
                        AddLine(TempChangedLine, CodeCoverage, Hits);
                    end;
                end else begin
                    Written.Add(LineKey, Hits);
                    AddLine(TempNewLine, CodeCoverage, Hits);
                end;
            until CodeCoverage.Next() = 0;

        if TempNewLine.FindSet() then
            repeat
                CoverageLine := TempNewLine;
                CoverageLine.Insert();
            until TempNewLine.Next() = 0;
        if TempChangedLine.FindSet() then
            repeat
                CoverageLine.SetRange("Object Type", TempChangedLine."Object Type");
                CoverageLine.SetRange("Object ID", TempChangedLine."Object ID");
                CoverageLine.SetRange("Line No.", TempChangedLine."Line No.");
                CoverageLine.ModifyAll(Hits, TempChangedLine.Hits);
            until TempChangedLine.Next() = 0;
        LastWrite := CurrentDateTime();
    end;

    local procedure AddLine(var TempCoverageLine: Record "Coverage Line" temporary; CodeCoverage: Record System.Tooling."Code Coverage"; Hits: Integer)
    begin
        TempCoverageLine.Init();
        TempCoverageLine."Object Type" := CopyStr(Format(CodeCoverage."Object Type"), 1, MaxStrLen(TempCoverageLine."Object Type"));
        TempCoverageLine."Object ID" := CodeCoverage."Object ID";
        TempCoverageLine."Line No." := CodeCoverage."Line No.";
        TempCoverageLine.Hits := Hits;
        TempCoverageLine.Insert();
    end;

    /// <summary>
    /// What another session of this run already wrote. Nothing for a run that just
    /// started: startCoverage empties "Coverage Line".
    /// </summary>
    local procedure LoadWritten()
    var
        CoverageLine: Record "Coverage Line";
    begin
        if CoverageLine.FindSet() then
            repeat
                Written.Set(CoverageLine."Object Type" + ':' + Format(CoverageLine."Object ID", 0, 9) + ':' + Format(CoverageLine."Line No.", 0, 9), CoverageLine.Hits);
            until CoverageLine.Next() = 0;
    end;

    /// <summary>
    /// Whether no other codeunit of the suite is still waiting to run. The runner sets
    /// a codeunit's result after each of its test methods, so the one that just ran
    /// already has one.
    /// </summary>
    local procedure IsLastCodeunit(TestMethodLine: Record System.TestTools.TestRunner."Test Method Line"): Boolean
    var
        PendingLine: Record System.TestTools.TestRunner."Test Method Line";
    begin
        PendingLine.SetRange("Test Suite", TestMethodLine."Test Suite");
        PendingLine.SetRange("Line Type", PendingLine."Line Type"::Codeunit);
        PendingLine.SetRange(Run, true);
        PendingLine.SetRange(Result, PendingLine.Result::" ");
        PendingLine.SetFilter("Test Codeunit", '<>%1', TestMethodLine."Test Codeunit");
        exit(PendingLine.IsEmpty());
    end;

    local procedure Copy(Source: Dictionary of [Text, Integer]; var Target: Dictionary of [Text, Integer])
    var
        LineKey: Text;
    begin
        Clear(Target);
        foreach LineKey in Source.Keys() do
            Target.Add(LineKey, Source.Get(LineKey));
    end;

    local procedure CheckpointInterval(): Integer
    begin
        exit(120000);
    end;
}
