/// <summary>
/// Records the code coverage of a whole test run in the session that runs the tests
/// and stores it with the "Coverage Store".
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
/// last codeunit it reads the Code Coverage table once and stores every Code line of
/// the partner objects (per-tenant 50000..99899, ISV 1000000..74999999; not this
/// extension's own 99900..99999), 0-hit lines included, which is what makes a
/// percentage possible — as one CSV blob, not one record per line. In between, at
/// most once per checkpoint interval, it stores the covered lines so far, so a
/// session that dies mid-run loses at most that interval.
///
/// A run is one startCoverage: a generation of "Coverage Setup". Another session in
/// the same run — the runner reconnected after a session died — continues from what
/// was stored and adds its own hits to it.
/// </summary>
codeunit 99910 "Coverage Recorder"
{
    SingleInstance = true;
    Permissions = tabledata "Coverage Setup" = rm,
                  tabledata System.TestTools.TestRunner."Test Method Line" = r;

    var
        CoverageStore: Codeunit "Coverage Store";
        // Hits stored before the running log started, which its own hits add to; empty in a run's first session.
        BaseHits: Dictionary of [Text, Integer];
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
        // Starting the log clears the session's hits, so they count from here on top of what is stored.
        StopLog();
        CoverageStore.LoadHits(BaseHits);
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
    /// Stores the run's coverage so far. Complete stores every Code line of the loaded
    /// partner objects; a checkpoint only the covered ones.
    /// </summary>
    local procedure Write(Complete: Boolean)
    var
        CodeCoverage: Record System.Tooling."Code Coverage";
        Remaining: Dictionary of [Text, Integer];
        Csv: TextBuilder;
        LineKey: Text;
        Hits: Integer;
        BaseHit: Integer;
        HasBase: Boolean;
        LinesRead: Integer;
        LinesStored: Integer;
        StartedAt: DateTime;
    begin
        StartedAt := CurrentDateTime();
        HasBase := BaseHits.Count() > 0;
        if HasBase then
            Copy(BaseHits, Remaining);
        System.CodeCoverageRefresh();
        CodeCoverage.SetRange("Line Type", CodeCoverage."Line Type"::Code);
        CodeCoverage.SetFilter("Object ID", '50000..99899|1000000..74999999');
        if not Complete then
            CodeCoverage.SetFilter("No. of Hits", '>0');
        if CodeCoverage.FindSet() then
            repeat
                LinesRead += 1;
                LineKey := Format(CodeCoverage."Object Type") + ',' + Format(CodeCoverage."Object ID", 0, 9) + ',' + Format(CodeCoverage."Line No.", 0, 9);
                Hits := CodeCoverage."No. of Hits";
                if HasBase then
                    if Remaining.Get(LineKey, BaseHit) then begin
                        Hits += BaseHit;
                        Remaining.Remove(LineKey);
                    end;
                Csv.AppendLine(LineKey + ',' + Format(Hits, 0, 9));
            until CodeCoverage.Next() = 0;
        LinesStored := LinesRead;
        // Lines an earlier session of this run recorded that this one did not load.
        foreach LineKey in Remaining.Keys() do begin
            Csv.AppendLine(LineKey + ',' + Format(Remaining.Get(LineKey), 0, 9));
            LinesStored += 1;
        end;

        CoverageStore.Save(Csv.ToText());
        LastWrite := CurrentDateTime();
        RecordWrite(LastWrite - StartedAt, LinesRead, LinesStored);
    end;

    local procedure RecordWrite(Took: Duration; LinesRead: Integer; LinesStored: Integer)
    var
        CoverageSetup: Record "Coverage Setup";
    begin
        if not CoverageSetup.Get() then
            exit;
        CoverageSetup.Writes += 1;
        CoverageSetup."Write Time" += Took;
        CoverageSetup."Last Write Lines Read" := LinesRead;
        CoverageSetup."Last Write Lines Stored" := LinesStored;
        CoverageSetup."Last Write Base Lines" := BaseHits.Count();
        CoverageSetup."Last Write At" := LastWrite;
        CoverageSetup.Modify();
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
