# Build stage: compile StartupHook + stubs + tools
FROM --platform=linux/amd64 mcr.microsoft.com/dotnet/sdk:8.0 AS builder

# gcc needed for compiling Win32 P/Invoke stubs (kernel32_stubs.c → libwin32_stubs.so);
# unzip for extracting libSkiaSharp.so out of NuGet packages (nupkg = zip)
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev unzip && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY src/ src/
COPY tools/ tools/
RUN cd src/StartupHook && dotnet publish -c Release -o /build/output/hook
# Web client startup hook (separate from the NST hook — see docs/WEBCLIENT-POC.md)
RUN cd src/WebClientHook && dotnet publish -c Release -o /build/output/webclient-hook

RUN cp /build/src/stubs/DrawingStub/bin/Release/net8.0/System.Drawing.Common.dll /build/output/DrawingStub.dll

# Publish tools
RUN cd src/tools/MergeNetstandard && dotnet publish -c Release -o /build/output/tools 2>&1 | tail -3
RUN cd src/tools/PatchNclTestPage && dotnet publish -c Release -o /build/output/tools/patcher 2>&1 | tail -3
# TestRunner — bundled in the image so run-tests.sh can invoke it via
# `docker compose exec` instead of `dotnet run`, removing the host-side
# .NET 8 SDK requirement for running tests against a Linux BC container.
RUN cd tools/TestRunner && dotnet publish -c Release -o /build/output/tools/TestRunner 2>&1 | tail -3

# Native libSkiaSharp.so for BC's report renderer, one per SkiaSharp line
# Microsoft has shipped (BC 28.x = 3.119.0; 2.88.9 covers the 2.88.x line).
# The entrypoint version-matches the artifact's managed SkiaSharp.dll and links
# the right one (plus the harfbuzz symlink) into the service dir — see the
# "report rendering natives" step there. nupkgs are plain zips.
RUN mkdir -p /build/output/skia && \
    for v in 2.88.9 3.119.0; do \
      curl -fsSL "https://www.nuget.org/api/v2/package/SkiaSharp.NativeAssets.Linux/$v" -o /tmp/skia.nupkg && \
      unzip -j -o /tmp/skia.nupkg "runtimes/linux-x64/native/libSkiaSharp.so" -d /build/output/skia/$v && \
      rm /tmp/skia.nupkg; \
    done && ls -la /build/output/skia/*

# Copy .NET 8 reference assemblies from SDK (needed for Cecil type resolution)
RUN mkdir -p /build/output/refasm && \
    REF_DIR=$(find /usr/share/dotnet/packs/Microsoft.NETCore.App.Ref -maxdepth 3 -type d -name "net8.0" | head -1) && \
    cp "$REF_DIR"/*.dll /build/output/refasm/ && \
    echo "Copied $(ls /build/output/refasm/*.dll | wc -l) reference assemblies"

# Runtime stage: minimal image
FROM --platform=linux/amd64 mcr.microsoft.com/dotnet/aspnet:8.0

# Install tools for artifact download and SQL setup + en_US locale.
# harfbuzz/freetype/fontconfig/fonts: BC's report renderer text-shapes via native
# P/Invoke ("harfbuzz", Aspose.Words) and rasterizes via SkiaSharp — without them
# every report render dies ("Text shaper factory failed to return text shaper").
# fonts-liberation is metric-compatible with Arial/Times, the RDLC defaults.
# NOTE: deliberately NO global libharfbuzz.so dev symlink here — harfbuzz must
# only become resolvable together with a version-matched libSkiaSharp.so (the
# entrypoint links both into the service dir, or neither): shaping-works-but-
# Skia-missing crashes the whole NST via SkiaSharp's SKObject finalizer, which
# is strictly worse than the graceful per-test shaper failure.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl unzip python3 gnupg locales \
        libharfbuzz0b libfreetype6 fontconfig fonts-liberation && \
    sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && locale-gen && \
    curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" > /etc/apt/sources.list.d/mssql.list && \
    ACCEPT_EULA=Y apt-get update && ACCEPT_EULA=Y apt-get install -y --no-install-recommends mssql-tools18 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /bc/hook /bc/patched /bc/refasm /bc/addins-overlay /bc/testrunner /bc/service /bc/artifacts /bc/scripts /bc/tools

# Copy built artifacts from builder
COPY --from=builder /build/output/hook/ /bc/hook/
COPY --from=builder /build/output/webclient-hook/ /bc/webclient-hook/
COPY --from=builder /build/output/refasm/ /bc/refasm/
COPY --from=builder /build/output/tools/ /bc/tools/
COPY --from=builder /build/output/DrawingStub.dll /bc/addins-overlay/System.Drawing.Common.dll
COPY --from=builder /build/output/skia/ /bc/natives/skia/

# Copy scripts
COPY scripts/ /bc/scripts/
RUN chmod +x /bc/scripts/*.sh

# Copy test runner extension (REST API for test execution)
COPY extensions/TestRunnerExtension/TestRunnerExtension.app /bc/testrunner/TestRunner.app

# Copy SideService stubs (Linux replacements for Windows PE executables)
COPY stubs/reporting-service-stub /bc/stubs/reporting-service-stub
COPY stubs/reporting-service-stub.dll /bc/stubs/reporting-service-stub.dll
COPY stubs/reporting-service-stub.runtimeconfig.json /bc/stubs/reporting-service-stub.runtimeconfig.json

ENV DOTNET_STARTUP_HOOKS=/bc/hook/StartupHook.dll \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8
EXPOSE 7045-7054 7083 7085-7089

ENTRYPOINT ["/bc/scripts/entrypoint.sh"]
