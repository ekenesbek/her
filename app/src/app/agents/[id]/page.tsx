import { requireUser } from "@/server/auth";
import { getAgent } from "@/server/db";
import { notFound } from "next/navigation";
import AgentEditor from "@/ui/agents/agent-editor";

export const dynamic = "force-dynamic";

export default async function AgentDetail({ params }: { params: Promise<{ id: string }> }) {
  const user = await requireUser();
  const { id } = await params;
  const agent = getAgent(id, user.id);
  if (!agent) notFound();
  return <AgentEditor agent={agent} />;
}
