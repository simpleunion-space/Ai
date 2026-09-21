# syntax=docker/dockerfile:1.7
FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS build

WORKDIR /repo
COPY --from=mcp-readonly-common src/McpReadonly.Common/McpReadonly.Common.csproj mcp-readonly-common/src/McpReadonly.Common/
COPY src/JiraReadonlyMcp/JiraReadonlyMcp.csproj jira-readonly-mcp/src/JiraReadonlyMcp/
RUN dotnet restore jira-readonly-mcp/src/JiraReadonlyMcp/JiraReadonlyMcp.csproj

COPY --from=mcp-readonly-common src/McpReadonly.Common/*.cs mcp-readonly-common/src/McpReadonly.Common/
COPY src/JiraReadonlyMcp/ jira-readonly-mcp/src/JiraReadonlyMcp/
RUN dotnet publish jira-readonly-mcp/src/JiraReadonlyMcp/JiraReadonlyMcp.csproj \
    --configuration Release \
    --no-restore \
    --output /out \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled

WORKDIR /app
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
    ASPNETCORE_URLS=http://+:8080
COPY --from=build /out/ ./

USER 10000:20000
EXPOSE 8080
ENTRYPOINT ["dotnet", "JiraReadonlyMcp.dll"]
