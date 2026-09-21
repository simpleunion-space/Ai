FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS build

WORKDIR /src
COPY --from=mcp-readonly-common src/McpReadonly.Common/McpReadonly.Common.csproj mcp-readonly-common/src/McpReadonly.Common/
COPY src/ConfluenceReadonlyMcp/ConfluenceReadonlyMcp.csproj confluence-readonly-mcp/src/ConfluenceReadonlyMcp/
RUN dotnet restore confluence-readonly-mcp/src/ConfluenceReadonlyMcp/ConfluenceReadonlyMcp.csproj

# Copy source files explicitly: a named context may contain host-generated
# obj/project.assets.json files whose Windows fallback paths are invalid here.
COPY --from=mcp-readonly-common src/McpReadonly.Common/*.cs mcp-readonly-common/src/McpReadonly.Common/
COPY src/ConfluenceReadonlyMcp/ confluence-readonly-mcp/src/ConfluenceReadonlyMcp/
RUN dotnet publish confluence-readonly-mcp/src/ConfluenceReadonlyMcp/ConfluenceReadonlyMcp.csproj \
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
ENTRYPOINT ["dotnet", "ConfluenceReadonlyMcp.dll"]
