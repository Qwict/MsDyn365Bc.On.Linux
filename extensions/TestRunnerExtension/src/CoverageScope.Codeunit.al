/// <summary>
/// What a coverage run measures: the apps under test and their objects with code.
///
/// An app is found through "NAV App Installed App" and its objects through AllObj on
/// "App Package ID" — the installed app's Package ID. "App Runtime Package ID" is not
/// the same value for every app and would miss objects. Only objects that can hold code
/// are in scope, and never this extension's own. An app id that is not a GUID, is not
/// installed, or is this extension is ignored, not an error, and listed so the report
/// can say what was asked for but not measured.
///
/// Without a scope (startCoverage of an older run-tests.sh) the scope is "legacy": every
/// loaded object in the partner ID ranges, and nothing is included up front.
/// </summary>
codeunit 99912 "Coverage Scope"
{
    Permissions = tabledata AllObj = r,
                  tabledata "NAV App Installed App" = r;

    var
        TempScopeApp: Record "Coverage Scope App" temporary;
        ObjectType: Codeunit "Coverage Object Type";
        // Object key ("Codeunit,50100") to the id of the app it belongs to.
        ObjectApps: Dictionary of [Text, Text];
        // The same keys in the order found: a Dictionary does not promise any order.
        ObjectKeys: List of [Text];
        // Distinct object IDs in scope, ascending.
        ObjectIds: List of [Integer];
        IgnoredAppIds: List of [Text];
        Legacy: Boolean;

    /// <summary>
    /// Works out the scope: the objects of the apps in AppIds (comma separated GUIDs), or
    /// the legacy scope when the run named no apps.
    /// </summary>
    procedure Resolve(Scoped: Boolean; AppIds: Text)
    var
        AppIdText: Text;
    begin
        TempScopeApp.Reset();
        TempScopeApp.DeleteAll();
        Clear(ObjectApps);
        Clear(ObjectKeys);
        Clear(ObjectIds);
        Clear(IgnoredAppIds);
        Legacy := not Scoped;
        if Legacy then
            exit;
        foreach AppIdText in AppIds.Split(',') do
            ResolveApp(AppIdText.Trim());
    end;

    procedure IsLegacy(): Boolean
    begin
        exit(Legacy);
    end;

    /// <summary>
    /// Registers the scope's objects with the platform's coverage log, so objects no test
    /// loads still get their lines, at 0 hits. The log must already be on: Include does
    /// nothing while it is off. Table, page and report extensions are not loaded by it;
    /// they only get lines once their code runs.
    /// </summary>
    procedure IncludeInLog()
    var
        AllObj: Record AllObj;
    begin
        if TempScopeApp.FindSet() then
            repeat
                AllObj.SetRange("App Package ID", TempScopeApp."Package ID");
                SetCodeObjectTypes(AllObj);
                CodeCoverageInclude(AllObj);
            until TempScopeApp.Next() = 0;
    end;

    /// <summary>
    /// The apps in scope, for the report.
    /// </summary>
    procedure GetApps(var TempApp: Record "Coverage Scope App" temporary)
    begin
        TempApp.Copy(TempScopeApp, true);
    end;

    procedure GetIgnoredAppIds(): List of [Text]
    begin
        exit(IgnoredAppIds);
    end;

    /// <summary>
    /// The scope's object keys, in the order they were found. Empty in the legacy scope,
    /// which has no list of objects.
    /// </summary>
    procedure GetObjectKeys(): List of [Text]
    begin
        exit(ObjectKeys);
    end;

    procedure GetAppId(ObjectKey: Text): Text
    var
        AppId: Text;
    begin
        if ObjectApps.Get(ObjectKey, AppId) then
            exit(AppId);
    end;

    /// <summary>
    /// Whether an object, by its key, belongs to the run. The legacy scope relies on the
    /// ID filter alone.
    /// </summary>
    procedure Contains(ObjectKey: Text): Boolean
    begin
        exit(Legacy or ObjectApps.ContainsKey(ObjectKey));
    end;

    /// <summary>
    /// The Object ID filter to read the Code Coverage table with, as compressed ranges.
    /// The table is indexed on Object ID; a read on anything else scans every object of
    /// the database. Empty when the scope has no objects: there is nothing to read.
    /// </summary>
    procedure ObjectIdFilter(): Text
    var
        Gap: Integer;
        RangeFilter: Text;
    begin
        if Legacy then
            exit('50000..99899|1000000..74999999');
        if ObjectIds.Count() = 0 then
            exit('');
        // A filter string has a length limit, so an app with many scattered IDs has its
        // ranges merged over bigger gaps until it fits. The scope check on each row then
        // drops the IDs the wider ranges let through.
        Gap := 0;
        repeat
            RangeFilter := BuildRangeFilter(Gap);
            Gap := NextGap(Gap);
        until (StrLen(RangeFilter) <= MaxFilterLength()) or (Gap > ObjectIds.Get(ObjectIds.Count())) or (Gap > MaxGap());
        if StrLen(RangeFilter) > MaxFilterLength() then
            RangeFilter := Format(ObjectIds.Get(1), 0, 9) + '..' + Format(ObjectIds.Get(ObjectIds.Count()), 0, 9);
        exit(RangeFilter);
    end;

    local procedure ResolveApp(AppIdText: Text)
    var
        InstalledApp: Record "NAV App Installed App";
        AppId: Guid;
    begin
        if AppIdText = '' then
            exit;
        if not Evaluate(AppId, AppIdText) then begin
            IgnoredAppIds.Add(AppIdText);
            exit;
        end;
        InstalledApp.SetRange("App ID", AppId);
        if IsOwnApp(AppId) or not InstalledApp.FindFirst() then begin
            IgnoredAppIds.Add(AppIdKey(AppId));
            exit;
        end;
        if TempScopeApp.Get(AppId) then
            exit;
        TempScopeApp.Init();
        TempScopeApp."App ID" := AppId;
        TempScopeApp."Package ID" := InstalledApp."Package ID";
        TempScopeApp.Name := InstalledApp.Name;
        TempScopeApp.Publisher := InstalledApp.Publisher;
        TempScopeApp.Version := CopyStr(AppVersion(InstalledApp), 1, MaxStrLen(TempScopeApp.Version));
        TempScopeApp.Insert();
        CollectObjects(AppId, InstalledApp."Package ID");
    end;

    local procedure CollectObjects(AppId: Guid; PackageId: Guid)
    var
        AllObj: Record AllObj;
        ObjectKey: Text;
        Ordinal: Integer;
    begin
        AllObj.SetRange("App Package ID", PackageId);
        SetCodeObjectTypes(AllObj);
        if AllObj.FindSet() then
            repeat
                Ordinal := AllObj."Object Type";
                ObjectKey := ObjectType.ObjectKey(Ordinal, AllObj."Object ID");
                if not ObjectApps.ContainsKey(ObjectKey) then
                    ObjectKeys.Add(ObjectKey);
                ObjectApps.Set(ObjectKey, AppIdKey(AppId));
                AddObjectId(AllObj."Object ID");
            until AllObj.Next() = 0;
    end;

    /// <summary>
    /// Limits AllObj to the object types that hold executable code.
    /// </summary>
    local procedure SetCodeObjectTypes(var AllObj: Record AllObj)
    begin
        AllObj.SetFilter("Object Type", '%1|%2|%3|%4|%5|%6|%7|%8|%9',
            AllObj."Object Type"::Table, AllObj."Object Type"::Report, AllObj."Object Type"::Codeunit,
            AllObj."Object Type"::XMLport, AllObj."Object Type"::Page, AllObj."Object Type"::Query,
            AllObj."Object Type"::TableExtension, AllObj."Object Type"::PageExtension,
            AllObj."Object Type"::ReportExtension);
    end;

    local procedure IsOwnApp(AppId: Guid): Boolean
    var
        OwnApp: ModuleInfo;
    begin
        NavApp.GetCurrentModuleInfo(OwnApp);
        exit(OwnApp.Id = AppId);
    end;

    local procedure AppIdKey(AppId: Guid): Text
    begin
        exit(Format(AppId, 0, 4).ToLower());
    end;

    local procedure AppVersion(InstalledApp: Record "NAV App Installed App"): Text
    begin
        exit(StrSubstNo('%1.%2.%3.%4', InstalledApp."Version Major", InstalledApp."Version Minor", InstalledApp."Version Build", InstalledApp."Version Revision"));
    end;

    /// <summary>
    /// Adds an ID to the sorted list of distinct IDs, by binary search.
    /// </summary>
    local procedure AddObjectId(ObjectId: Integer)
    var
        Low: Integer;
        High: Integer;
        Middle: Integer;
    begin
        Low := 1;
        High := ObjectIds.Count();
        while Low <= High do begin
            Middle := (Low + High) div 2;
            if ObjectIds.Get(Middle) = ObjectId then
                exit;
            if ObjectIds.Get(Middle) < ObjectId then
                Low := Middle + 1
            else
                High := Middle - 1;
        end;
        ObjectIds.Insert(Low, ObjectId);
    end;

    /// <summary>
    /// The IDs as a filter of ranges, joining IDs that are at most Gap + 1 apart.
    /// </summary>
    local procedure BuildRangeFilter(Gap: Integer): Text
    var
        RangeFilter: TextBuilder;
        ObjectId: Integer;
        RangeStart: Integer;
        RangeEnd: Integer;
    begin
        RangeStart := ObjectIds.Get(1);
        RangeEnd := RangeStart;
        foreach ObjectId in ObjectIds do
            if ObjectId - RangeEnd > Gap + 1 then begin
                AppendRange(RangeFilter, RangeStart, RangeEnd);
                RangeStart := ObjectId;
                RangeEnd := ObjectId;
            end else
                RangeEnd := ObjectId;
        AppendRange(RangeFilter, RangeStart, RangeEnd);
        exit(RangeFilter.ToText());
    end;

    local procedure AppendRange(var RangeFilter: TextBuilder; RangeStart: Integer; RangeEnd: Integer)
    begin
        if RangeFilter.Length() > 0 then
            RangeFilter.Append('|');
        RangeFilter.Append(Format(RangeStart, 0, 9));
        if RangeEnd > RangeStart then
            RangeFilter.Append('..' + Format(RangeEnd, 0, 9));
    end;

    local procedure NextGap(Gap: Integer): Integer
    begin
        // Growing past the cap would overflow an Integer; the caller stops there and
        // falls back to one range from the lowest to the highest ID.
        if Gap >= MaxGap() then
            exit(MaxGap() + 1);
        if Gap = 0 then
            exit(10);
        exit(Gap * 10);
    end;

    local procedure MaxGap(): Integer
    begin
        exit(100000000);
    end;

    local procedure MaxFilterLength(): Integer
    begin
        exit(1800);
    end;
}
