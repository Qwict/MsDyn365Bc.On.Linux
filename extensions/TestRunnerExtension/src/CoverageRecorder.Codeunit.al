/// <summary>
/// Records the code coverage of a whole test run in the session that runs the tests
/// and stores it with the "Coverage Store".
///
/// Microsoft's Test Runner can record coverage itself, but only by starting and
/// stopping the platform's coverage log around every test codeunit and handing an
/// exporter the session's whole Code Coverage table each time. That made a covered run
/// three to eight times slower than a plain one, nearly all of it between the codeunits,
/// and it only ever saw the objects the tests happened to load.
///
/// This recorder starts the log once, before the first test codeunit of a run, and
/// leaves it running, so the platform adds up the hits of the whole run. Right after
/// starting it includes the objects of the run's scope ("Coverage Scope") and stores the
/// inventory: every line of the scope at 0 hits. A run that dies early thus still has its
/// denominator. After that it stores the run so far between test codeunits, as often as
/// the checkpoint policy allows (CheckpointDue), and once more after the last codeunit,
/// which marks the report complete. Every write reads only the scope's
/// objects ("Coverage Reader"), so its cost follows the size of the apps under test.
///
/// A run is one startCoverage or startCoverageForApps: a generation of "Coverage Setup".
/// Another session in the same run, the runner reconnected after a session died,
/// continues from what was stored and adds its own hits to it.
/// </summary>
codeunit 99910 "Coverage Recorder"
{
    SingleInstance = true;
    Permissions = tabledata "Coverage Setup" = rm,
                  tabledata System.TestTools.TestRunner."Test Method Line" = r;

    var
        Scope: Codeunit "Coverage Scope";
        Reader: Codeunit "Coverage Reader";
        Builder: Codeunit "Coverage Report Builder";
        Store: Codeunit "Coverage Store";
        Recording: Boolean;
        RunGeneration: Integer;
        RunStartedAt: DateTime;
        LastWrite: DateTime;
        LastWriteMs: BigInteger;
        IncludeMs: BigInteger;
        InventoryLines: Integer;

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
        StartLog(CoverageSetup);
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::System.TestTools.TestRunner."Test Runner - Mgt", 'OnAfterCodeunitRun', '', false, false)]
    local procedure OnAfterCodeunitRun(var TestMethodLine: Record System.TestTools.TestRunner."Test Method Line")
    begin
        if not Recording then
            exit;
        if IsLastCodeunit(TestMethodLine) then begin
            Write(true, false);
            StopLog();
        end else
            if CheckpointDue() then
                Write(false, false);
    end;

    /// <summary>
    /// Starts the log for the run, then includes the scope and stores the inventory. The
    /// order matters: Include does nothing while the log is off, and starting the log
    /// clears the session's hits, so they count from here on top of what is stored.
    /// </summary>
    local procedure StartLog(CoverageSetup: Record "Coverage Setup")
    var
        IncludeStartedAt: DateTime;
    begin
        StopLog();
        Scope.Resolve(CoverageSetup.Scoped, CoverageSetup."Scope App Ids");
        Reader.LoadBase();
        CodeCoverageLog(true, CoverageSetup."Multi Session");
        IncludeStartedAt := CurrentDateTime();
        Scope.IncludeInLog();
        IncludeMs := CurrentDateTime() - IncludeStartedAt;
        Recording := true;
        RunGeneration := CoverageSetup.Generation;
        RunStartedAt := CoverageSetup."Started At";
        LastWriteMs := 0;
        InventoryLines := 0;
        Write(false, true);
        InventoryLines := Builder.GetLineCount();
    end;

    local procedure StopLog()
    begin
        if not Recording then
            exit;
        CodeCoverageLog(false, false);
        Recording := false;
    end;

    /// <summary>
    /// Stores the run's coverage so far: every line of the scope with its hits. Complete
    /// marks the report as the finished run's.
    /// </summary>
    local procedure Write(Complete: Boolean; Inventory: Boolean)
    var
        CoverageSetup: Record "Coverage Setup";
        StartedAt: DateTime;
        RowsRead: Integer;
    begin
        StartedAt := CurrentDateTime();
        Builder.Initialize(RunGeneration, Complete, RunStartedAt);
        if CoverageSetup.Get() then
            Builder.SetDiagnostics(CoverageSetup.Writes, CoverageSetup."Write Time", LastWriteMs, IncludeMs, InventoryLines, Inventory);
        RowsRead := Reader.ReadInto(Scope, Builder);
        Store.Save(Builder.ToText(Scope), Complete, Builder);
        LastWrite := CurrentDateTime();
        LastWriteMs := LastWrite - StartedAt;
        RecordWrite(LastWrite - StartedAt, RowsRead);
    end;

    local procedure RecordWrite(Took: Duration; RowsRead: Integer)
    var
        CoverageSetup: Record "Coverage Setup";
    begin
        if not CoverageSetup.Get() then
            exit;
        CoverageSetup.Writes += 1;
        CoverageSetup."Write Time" += Took;
        CoverageSetup."Last Write Lines Read" := RowsRead;
        CoverageSetup."Last Write Lines Stored" := Builder.GetLineCount();
        CoverageSetup."Last Write Base Lines" := Reader.BaseLineCount();
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

    /// <summary>
    /// Whether a checkpoint is due between two test codeunits: when the time since the last
    /// write is at least twenty times what that write took, and at least ten seconds. A
    /// write then costs about 5% of the run however large the apps under test are, and a
    /// session that dies loses the hits of the last interval only, which on a small app is
    /// ten seconds. A fixed interval would be too slow for a small app and too heavy for
    /// a big one.
    /// </summary>
    local procedure CheckpointDue(): Boolean
    var
        Interval: BigInteger;
    begin
        Interval := 20 * LastWriteMs;
        if Interval < 10000 then
            Interval := 10000;
        exit(CurrentDateTime() - LastWrite >= Interval);
    end;
}
