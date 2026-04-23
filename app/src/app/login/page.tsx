import { redirect } from "next/navigation";
import { getCurrentUser } from "@/lib/auth";
import PasskeyAuth from "./passkey-auth";

export const dynamic = "force-dynamic";

export default async function LoginPage() {
  const user = await getCurrentUser();
  if (user) redirect("/");

  return <PasskeyAuth />;
}
