import { requireUser } from "@/server/auth";
import { resolveBrowserConnection } from "@/server/browser";
import {
  getAgent,
  getBrowserSettings,
  getChatThread,
  getOrCreateLatestChatThread,
  listChatThreads,
  listMessages,
} from "@/server/db";
import { notFound, redirect } from "next/navigation";
import ChatClient from "@/ui/chat/chat-client";

export const dynamic = "force-dynamic";

export default async function ChatPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ chatId?: string }>;
}) {
  const user = await requireUser();
  const { id } = await params;
  const query = await searchParams;
  const agent = getAgent(id, user.id);
  if (!agent) notFound();
  const requestedThread = query.chatId ? getChatThread(id, user.id, query.chatId) : null;
  const activeThread = requestedThread ?? getOrCreateLatestChatThread(id, user.id);
  if (query.chatId !== activeThread.id) {
    redirect(`/chat/${id}?chatId=${activeThread.id}`);
  }

  const threads = listChatThreads(id, user.id);
  const history = listMessages(id, user.id, activeThread.id);
  const browserConnection = resolveBrowserConnection(getBrowserSettings(user.id));
  return (
    <ChatClient
      key={activeThread.id}
      agent={agent}
      activeChatId={activeThread.id}
      chatThreads={threads}
      initialMessages={history}
      browserConnection={browserConnection}
    />
  );
}
