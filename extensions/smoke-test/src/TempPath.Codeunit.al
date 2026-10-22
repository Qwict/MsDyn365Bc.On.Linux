// Regression guard for issue #122, item 1: File.IsPathTemporary said true for every path.
//
// BC's IsPathTemporary is "ExpandFileName with the user-folder check on did not throw".
// Patch #28 turned that check off, so every path counted as temporary, drive letters and
// UNC paths included. Patch #35 answers the question again: a path is temporary when it
// resolves inside the session's user folder, and a drive letter or a UNC path never does.
//
// Every expected value is what an official Windows container reported (BC 27.5 and 29.0).
codeunit 70013 "BC Linux Temp Path Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure PathsInsideTheTemporaryFolderAreTemporary()
    var
        Temp: Text;
    begin
        Temp := TemporaryPath();
        LibraryAssert.IsTrue(File.IsPathTemporary(Temp), 'TemporaryPath()');
        LibraryAssert.IsTrue(File.IsPathTemporary(Temp + 'bclinux.tmp'), 'a file in TemporaryPath()');
        LibraryAssert.IsTrue(File.IsPathTemporary(Temp + 'bclinux-sub/bclinux.tmp'), 'a file in a subfolder');
        LibraryAssert.IsTrue(File.IsPathTemporary('bclinux-relative.tmp'), 'a relative path');
        LibraryAssert.IsTrue(File.IsPathTemporary(''), 'an empty path');
    end;

    [Test]
    procedure PathsOutsideTheTemporaryFolderAreNot()
    begin
        LibraryAssert.IsFalse(File.IsPathTemporary('C:\bclinux.tmp'), 'C:\');
        LibraryAssert.IsFalse(File.IsPathTemporary('Z:/bclinux.tmp'), 'Z:/');
        LibraryAssert.IsFalse(File.IsPathTemporary('\\bclinux-server\share\bclinux.tmp'), 'a UNC path');
        LibraryAssert.IsFalse(File.IsPathTemporary('/'), '/');
    end;
}
