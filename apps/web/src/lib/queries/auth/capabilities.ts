import { SERVER_HOSTS } from '@core/constant/servers';
import { useQuery } from '@tanstack/solid-query';

/**
 * Which external integrations this deployment has configured, as reported by
 * the auth service's `/capabilities` endpoint. The web client hides SSO/connect
 * UI for unconfigured providers (graceful degradation for self-host).
 */
export type Capabilities = {
  google_login: boolean;
  github_login: boolean;
  microsoft_login: boolean;
  stripe_billing: boolean;
};

/**
 * Fallback when the endpoint is unreachable or returns a non-2xx (e.g. an
 * older backend without `/capabilities`). Defaulting to "everything on"
 * preserves upstream behavior rather than hiding features by mistake.
 */
export const DEFAULT_CAPABILITIES: Capabilities = {
  google_login: true,
  github_login: true,
  microsoft_login: true,
  stripe_billing: true,
};

export async function fetchCapabilities(): Promise<Capabilities> {
  const response = await fetch(`${SERVER_HOSTS['auth-service']}/capabilities`);
  if (!response.ok) return DEFAULT_CAPABILITIES;
  const body = (await response.json().catch(() => null)) as Capabilities | null;
  if (!body || typeof body !== 'object') return DEFAULT_CAPABILITIES;
  return {
    google_login: body.google_login ?? true,
    github_login: body.github_login ?? true,
    microsoft_login: body.microsoft_login ?? true,
    stripe_billing: body.stripe_billing ?? true,
  };
}

export function capabilitiesQueryOptions() {
  return {
    queryKey: ['integrations-capabilities'],
    queryFn: fetchCapabilities,
    // Resolved once per session; integration config does not change at runtime.
    staleTime: Infinity,
    refetchOnWindowFocus: false,
  };
}

export function useCapabilities() {
  return useQuery(() => capabilitiesQueryOptions());
}
