// Only the retired ai-stand MetaMCP OIDC pair (removed 2026-10-23) may be removed. Native Authentik
// DELETE cascades its application policy bindings and provider-owned OAuth
// grants; shared flows, mappings, signing keys, users and groups are untouched.
export async function cleanupMetamcpArtifacts({ api, list, log = () => {} }) {
  const slug = "metamcp";
  const name = "ai-stand-metamcp-oidc";
  const application = await api("GET", `/core/applications/${slug}/`, undefined, { allow404: true });
  const matches = (await list("/providers/oauth2/", { search: name }))
    .filter((provider) => provider.name === name);
  if (matches.length > 1) throw new Error("Refusing MetaMCP cleanup: duplicate managed OIDC provider name");
  const provider = matches[0];

  // Resolve all ownership before any DELETE. Search is not an identity check.
  if (provider && provider.client_id !== "metamcp") {
    throw new Error("Refusing MetaMCP cleanup: managed provider has an unexpected client ID");
  }
  if (application?.provider != null && String(application.provider) !== String(provider?.pk)) {
    throw new Error("Refusing MetaMCP cleanup: application references another provider");
  }
  if (provider) {
    const applications = await list("/core/applications/");
    const foreignReferences = applications.filter((app) => app.slug !== slug && (
      String(app.provider) === String(provider.pk)
      || (app.backchannel_providers ?? []).some((pk) => String(pk) === String(provider.pk))
    ));
    if (foreignReferences.length > 0) {
      throw new Error("Refusing MetaMCP cleanup: provider is referenced by another application");
    }
  }

  if (application) {
    await api("DELETE", `/core/applications/${slug}/`);
    log("Retired MetaMCP application deleted");
  }
  if (provider) {
    await api("DELETE", `/providers/oauth2/${provider.pk}/`);
    log("Retired MetaMCP OIDC provider and provider-owned grants deleted");
  }

  const remainingApp = await api("GET", `/core/applications/${slug}/`, undefined, { allow404: true });
  const remainingProviders = (await list("/providers/oauth2/", { search: name }))
    .filter((item) => item.name === name);
  if (remainingApp || remainingProviders.length > 0) {
    throw new Error("MetaMCP cleanup failed: managed application or provider is still present");
  }
  log("Retired MetaMCP application and OIDC provider verified absent");
}
