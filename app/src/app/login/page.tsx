import { redirect } from "next/navigation";
import { getCurrentUser } from "@/server/auth";
import PasskeyAuth from "@/ui/auth/passkey-auth";

export const dynamic = "force-dynamic";

export default async function LoginPage() {
  const user = await getCurrentUser();
  if (user) redirect("/");

  return <PasskeyAuth />;
}
