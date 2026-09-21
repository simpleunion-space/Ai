# syntax=docker/dockerfile:1.7
FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS build

WORKDIR /workspace
COPY --from=mcp-readonly-common src/McpReadonly.Common/McpReadonly.Common.csproj mcp-readonly-common/src/McpReadonly.Common/
COPY src/ImapReadonlyMcp/ImapReadonlyMcp.csproj imap-readonly-mcp/src/ImapReadonlyMcp/
RUN dotnet restore imap-readonly-mcp/src/ImapReadonlyMcp/ImapReadonlyMcp.csproj

COPY --from=mcp-readonly-common src/McpReadonly.Common/*.cs mcp-readonly-common/src/McpReadonly.Common/
COPY src/ImapReadonlyMcp/ imap-readonly-mcp/src/ImapReadonlyMcp/
RUN dotnet publish imap-readonly-mcp/src/ImapReadonlyMcp/ImapReadonlyMcp.csproj \
    --configuration Release \
    --no-restore \
    --output /out \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled

WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080 \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
COPY --from=build /out/ ./

USER 10000:20000
EXPOSE 8080
ENTRYPOINT ["dotnet", "ImapReadonlyMcp.dll"]
