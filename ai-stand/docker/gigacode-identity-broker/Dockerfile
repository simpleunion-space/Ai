FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY GigacodeIdentityBroker.csproj ./
RUN dotnet restore GigacodeIdentityBroker.csproj
COPY Program.cs ./
RUN dotnet publish GigacodeIdentityBroker.csproj --configuration Release --no-restore --output /out /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /out/ ./
USER 10000:20000
EXPOSE 8080
ENTRYPOINT ["dotnet", "GigacodeIdentityBroker.dll"]
