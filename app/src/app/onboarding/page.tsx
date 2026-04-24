import { requireUser } from "@/server/auth";
import OnboardingWizard from "@/ui/onboarding/onboarding-wizard";
import { TEMPLATES } from "@/shared/templates";

export default async function OnboardingPage() {
  await requireUser();
  return <OnboardingWizard templates={TEMPLATES} />;
}
