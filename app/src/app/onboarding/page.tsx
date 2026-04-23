import { requireUser } from "@/lib/auth";
import OnboardingWizard from "./wizard";
import { TEMPLATES } from "@/lib/templates";

export default async function OnboardingPage() {
  await requireUser();
  return <OnboardingWizard templates={TEMPLATES} />;
}
