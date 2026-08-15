import { ENABLE_EMAIL } from '@core/constant/featureFlags';
import { Show, Suspense } from 'solid-js';
import { DEFAULT_CAPABILITIES, useCapabilities } from '@queries/auth/capabilities';
import { EmailCard } from './Email';
import { GitHubCard } from './GitHub';
import { IntegrationsSection } from './Integrations';
import { SettingsPage, SettingsSection } from './primitives';

/**
 * Consolidated "Connections" page: one card per external account the user can
 * link (Gmail, GitHub), plus the agent's MCP integrations — so everything
 * Macro is connected to lives in one place.
 */
export function ConnectedAccounts() {
  const capabilities = useCapabilities();
  const caps = () => capabilities.data ?? DEFAULT_CAPABILITIES;

  return (
    <SettingsPage
      title="Connections"
      description="Connect your accounts so Macro can work across the tools you already use."
    >
      <SettingsSection title="Accounts">
        <div class="flex flex-col gap-3">
          <Show when={ENABLE_EMAIL && caps().google_login}>
            <Suspense>
              <EmailCard />
            </Suspense>
          </Show>
          <Show when={caps().github_login}>
            <Suspense>
              <GitHubCard />
            </Suspense>
          </Show>
        </div>
      </SettingsSection>
      <Suspense>
        <IntegrationsSection />
      </Suspense>
    </SettingsPage>
  );
}
