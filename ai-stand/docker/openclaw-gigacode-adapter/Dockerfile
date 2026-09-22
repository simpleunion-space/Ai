FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY OpenclawGigacodeAdapter.csproj ./
RUN dotnet restore OpenclawGigacodeAdapter.csproj
COPY Program.cs ./
RUN dotnet publish OpenclawGigacodeAdapter.csproj --configuration Release --no-restore --output /out /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /out/ ./
USER 10000:20000
EXPOSE 8080
ENTRYPOINT ["dotnet", "OpenclawGigacodeAdapter.dll"]
