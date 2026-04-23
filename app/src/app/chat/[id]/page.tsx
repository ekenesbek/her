import { requireUser } from "@/lib/auth";
import { getAgent, listMessages } from "@/lib/db";
import { notFound } from "next/navigation";
import ChatClient from "./chat-client";

export const dynamic = "force-dynamic";

export default async function ChatPage({ params }: { params: Promise<{ id: string }> }) {
  const user = await requireUser();
  const { id } = await params;
  const agent = getAgent(id, user.id);
  if (!agent) notFound();
  const history = listMessages(id, user.id);
  return <ChatClient agent={agent} initialMessages={history} />;
}
