import { requireUser } from "@/lib/auth";
import { getAgent } from "@/lib/db";
import { notFound } from "next/navigation";
import AgentEditor from "./editor";

export const dynamic = "force-dynamic";

export default async function AgentDetail({ params }: { params: Promise<{ id: string }> }) {
  const user = await requireUser();
  const { id } = await params;
  const agent = getAgent(id, user.id);
  if (!agent) notFound();
  return <AgentEditor agent={agent} />;
}
