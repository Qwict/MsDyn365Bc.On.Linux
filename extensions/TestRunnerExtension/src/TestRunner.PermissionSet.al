permissionset 99905 "Test Runner Exec"
{
    Assignable = true;
    Caption = 'Test Runner Exec';
    Permissions =
        tabledata "Log Table" = RIMD,
        tabledata "Codeunit Run Request" = RIMD,
        tabledata "Coverage Line" = RIMD,
        tabledata "Coverage Setup" = RIMD,
        codeunit System.Apps."Extension Management" = X;
}
