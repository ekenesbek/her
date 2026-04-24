import { requireUser } from "@/server/auth";
import { resolveBrowserConnection } from "@/server/browser";
import { getBrowserSettings } from "@/server/db";
import BrowserSettingsForm from "@/ui/settings/browser-settings-form";

export const dynamic = "force-dynamic";

export default async function BrowserSettingsPage() {
  const user = await requireUser();
  const settings = getBrowserSettings(user.id);
  const connection = resolveBrowserConnection(settings);

  return <BrowserSettingsForm initialSettings={settings} initialConnection={connection} />;
}
