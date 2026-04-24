import { requireUser } from "@/server/auth";
import { resolveBrowserConnection } from "@/server/browser";
import { getAgent, getBrowserSettings, listMessages } from "@/server/db";
import { notFound } from "next/navigation";
import ChatClient from "@/ui/chat/chat-client";

export const dynamic = "force-dynamic";

export default async function ChatPage({ params }: { params: Promise<{ id: string }> }) {
  const user = await requireUser();
  const { id } = await params;
  const agent = getAgent(id, user.id);
  if (!agent) notFound();
  const history = listMessages(id, user.id);
  const browserConnection = resolveBrowserConnection(getBrowserSettings(user.id));
  return <ChatClient agent={agent} initialMessages={history} browserConnection={browserConnection} />;
}
