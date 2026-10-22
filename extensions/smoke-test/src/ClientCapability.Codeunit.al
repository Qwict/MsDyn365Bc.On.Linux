// Regression guard for issue #125, item 1: a RunOnClient DotNet in a test session.
//
// "if UserTours.IsAvailable() then" in "O365 Activities" OnInit made a TestPage of the
// Business Manager Role Center end in a NullReferenceException: both runners' client
// answered CreateDotNetHandle with null, and BC dereferenced it. A Windows test run's client
// (the web server's ObservingAutomationHandler) hands out a handle for a client extension
// type and says false to its IsAvailable, so the page opens. tools/TestRunner and Patch #37
// now answer the same way.
//
// This app has no Base Application, so the guard uses the System Application's Camera,
// which asks CameraProvider.IsAvailable() the same way. The Role Center itself was checked
// on BC 28.5 with both runners. False is what ObservingAutomationHandler returns for a
// session with no browser; it was read from Microsoft's code, not measured on Windows.
codeunit 70019 "BC Linux Client Capability"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure CameraIsNotAvailableInATestSession()
    var
        Camera: Codeunit Camera;
    begin
        LibraryAssert.IsFalse(Camera.IsAvailable(), 'Camera.IsAvailable() in a test session');
    end;
}
