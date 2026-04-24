import { getCurrentUser } from "@/server/auth";
import { listAgents } from "@/server/db";
import { redirect } from "next/navigation";

export default async function Home() {
  const user = await getCurrentUser();
  if (!user) redirect("/login");

  const agents = listAgents(user.id);
  if (agents.length === 0) redirect("/onboarding");
  redirect("/dashboard");
}
