// Smoke test codeunit 1: trivial sanity checks (date + arithmetic).
// Used by test-versions.yml to verify the bc-linux substrate end-to-end
// across all supported BC versions.
//
// NOTE ON THE DEPENDENCY — do not "fix" app.json by adding Test Runner.
// This fixture deliberately depends on Library Assert and NOT on Microsoft's
// Test Runner, because that is what a real consumer test app looks like:
// they declare Library Assert / Tests-TestLibraries, never Test Runner.
// Test Runner reaches the keep set only via bc-linux's own
// TestRunnerExtension app.json, which resolve-keep-app-ids.py auto-seeds.
// Declaring Test Runner here would paper over a broken seed and this matrix
// would go green while every consumer's test run failed with AL1024 — which
// is exactly what happened to the four inlined example pipelines until
// 2026-08-07. The assertions below go through Library Assert so the
// dependency is real and not just declarative.
codeunit 70000 "BC Linux Smoke Test 1"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure TestDateSanity()
    begin
        LibraryAssert.IsTrue(Today() >= 20200101D, 'Date sanity check failed');
    end;

    [Test]
    procedure TestBasicArithmetic()
    begin
        LibraryAssert.AreEqual(42, 6 * 7, 'Basic arithmetic failed');
    end;
}
