// Only the retired ai-stand GitLab OIDC pair may be removed. Native Authentik
// DELETE cascades its application policy bindings and provider-owned OAuth
// grants; shared flows, mappings, signing keys, users and groups are untouched.
export async function cleanupGitlabArtifacts({ api, list, log = () => {} }) {
  const slug = "gitlab";
  const name = "ai-stand-gitlab-oidc";
  const application = await api("GET", `/core/applications/${slug}/`, undefined, { allow404: true });
  const matches = (await list("/providers/oauth2/", { search: name }))
    .filter((provider) => provider.name === name);
  if (matches.length > 1) throw new Error("Refusing GitLab cleanup: duplicate managed OIDC provider name");
  const provider = matches[0];

  // Resolve all ownership before any DELETE. Search is not an identity check.
  if (provider && provider.client_id !== "gitlab") {
    throw new Error("Refusing GitLab cleanup: managed provider has an unexpected client ID");
  }
  if (application?.provider != null && String(application.provider) !== String(provider?.pk)) {
    throw new Error("Refusing GitLab cleanup: application references another provider");
  }
  if (provider) {
    const applications = await list("/core/applications/");
    const foreignReferences = applications.filter((app) => app.slug !== slug && (
      String(app.provider) === String(provider.pk)
      || (app.backchannel_providers ?? []).some((pk) => String(pk) === String(provider.pk))
    ));
    if (foreignReferences.length > 0) {
      throw new Error("Refusing GitLab cleanup: provider is referenced by another application");
    }
  }

  if (application) {
    await api("DELETE", `/core/applications/${slug}/`);
    log("Retired GitLab application deleted");
  }
  if (provider) {
    await api("DELETE", `/providers/oauth2/${provider.pk}/`);
    log("Retired GitLab OIDC provider and provider-owned grants deleted");
  }

  const remainingApp = await api("GET", `/core/applications/${slug}/`, undefined, { allow404: true });
  const remainingProviders = (await list("/providers/oauth2/", { search: name }))
    .filter((item) => item.name === name);
  if (remainingApp || remainingProviders.length > 0) {
    throw new Error("GitLab cleanup failed: managed application or provider is still present");
  }
  log("Retired GitLab application and OIDC provider verified absent");
}
