// Smoke test codeunit 2: trivial string + boolean checks.
// Used by test-versions.yml to verify the bc-linux substrate end-to-end
// across all supported BC versions.
//
// See SmokeTest1.Codeunit.al for why this fixture depends on Library Assert
// and deliberately NOT on Microsoft's Test Runner.
codeunit 70001 "BC Linux Smoke Test 2"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure TestStringConcatenation()
    var
        Result: Text;
    begin
        Result := 'Hello' + ', ' + 'World';
        LibraryAssert.AreEqual('Hello, World', Result, 'String concatenation failed');
    end;

    [Test]
    procedure TestBooleanLogic()
    begin
        LibraryAssert.IsTrue(true and not false, 'Boolean logic failed');
    end;
}
