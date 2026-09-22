FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS build

WORKDIR /src
COPY GigacodeSubscriptionBridge.csproj ./
RUN dotnet restore GigacodeSubscriptionBridge.csproj

COPY . ./
RUN dotnet publish GigacodeSubscriptionBridge.csproj \
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
ENTRYPOINT ["dotnet", "GigacodeSubscriptionBridge.dll"]
