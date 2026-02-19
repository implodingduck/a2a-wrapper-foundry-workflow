from multiprocessing import context
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.types import (
    Task,
    TaskState,
    TaskStatus
)
from a2a.utils import new_agent_text_message, get_message_text

import os
import time
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import ResponseStreamEventType



class FoundryWorkflowAgent:
    """Foundry Workflow Agent."""

    async def handle_stream(self, stream, conversation, full_response, openai_client, workflow) -> str:
        tool_approvals = []

        for event in stream:
            #print("-------------------------------")
            # if event.type == ResponseStreamEventType.RESPONSE_OUTPUT_TEXT_DONE:
            #     print("\t", event.text)
            # elif event.type == ResponseStreamEventType.RESPONSE_OUTPUT_ITEM_ADDED and event.item.type == "workflow_action":
            #     print(f"********************************\nActor - '{event.item.action_id}' :")
            # elif event.type == ResponseStreamEventType.RESPONSE_OUTPUT_ITEM_ADDED and event.item.type == "workflow_action":
            #     print(f"Workflow Item '{event.item.action_id}' is '{event.item.status}' - (previous item was : '{event.item.previous_action_id}')")
            # elif event.type == ResponseStreamEventType.RESPONSE_OUTPUT_ITEM_DONE and event.item.type == "workflow_action":
            #     print(f"Workflow Item '{event.item.action_id}' is '{event.item.status}' - (previous item was: '{event.item.previous_action_id}')")
            if event.type == ResponseStreamEventType.RESPONSE_OUTPUT_TEXT_DELTA:
                #print(f"\tDelta : {event.delta}")
                full_response.append(event.delta)
            
            elif event.type == ResponseStreamEventType.RESPONSE_OUTPUT_ITEM_DONE and event.item.type == "mcp_approval_request":
                print(f"Approval request for item '{event.item.id}' with arguments: {event.item.arguments}")

                tool_approvals.append({
                            "type": "mcp_approval_response",
                            "approve": True,  # Change to False to reject
                            "approval_request_id": event.item.id,
                        })
                

            elif event.type == ResponseStreamEventType.RESPONSE_COMPLETED:
                print("Workflow completed!")
                if len(tool_approvals) > 0:
                    print(f"Sending tool approvals: {tool_approvals}")
                    try:
                        # Approve the MCP tool request by creating a new response
                        approval_response = openai_client.responses.create(
                            conversation=conversation.id,
                            extra_body={"agent": {"name": workflow["name"], "type": "agent_reference"}},
                            input=tool_approvals,
                            stream=True
                        )
                        await self.handle_stream(approval_response, conversation, full_response, openai_client, workflow)
                    except Exception as e:
                        print(f"Error sending tool approval response: {e}")
                        print(f"Trying again in 3 seconds...")
                        time.sleep(3)  # Wait before retrying
                        try:
                            approval_response = openai_client.responses.create(
                                conversation=conversation.id,
                                extra_body={"agent": {"name": workflow["name"], "type": "agent_reference"}},
                                input=tool_approvals,
                                stream=True
                            )
                            await self.handle_stream(approval_response, conversation, full_response, openai_client, workflow)
                        except Exception as e:
                            print(f"Second attempt failed: {e}")
                #else:
                #    print(f"Final response: {event.response.content if hasattr(event, 'response') and hasattr(event.response, 'content') else event}")
            
            # else:
            #     print(f"Unknown event [{event.type} | {event.item.type if hasattr(event, 'item') and event.item else 'N/A'}]: {event}")
    
    async def invoke(self, text: str) -> str:
        print(f'FoundryWorkflowAgent received input: {text}')
        project_client = AIProjectClient(
            endpoint=os.environ.get('FOUNDRY_WORKFLOW_ENDPOINT'),
            credential=DefaultAzureCredential(),
        )
        
        full_response = []
        
        with project_client:

            workflow = {
                "name": os.environ.get('FOUNDRY_WORKFLOW_NAME'),
                "version": os.environ.get('FOUNDRY_WORKFLOW_VERSION', '1'),
            }
            
            openai_client = project_client.get_openai_client()

            conversation = openai_client.conversations.create()
            print(f"Created conversation (id: {conversation.id})")

            stream = openai_client.responses.create(
                conversation=conversation.id,
                extra_body={"agent": {"name": workflow["name"], "type": "agent_reference"}},
                input=text,  # Use the actual input text instead of hardcoded value
                stream=True,
                metadata={"x-ms-debug-mode-enabled": "1"},
            )

            await self.handle_stream(stream, conversation, full_response, openai_client, workflow)
            

            openai_client.conversations.delete(conversation_id=conversation.id)
            print("Conversation deleted")

        # Return the full response text
        retval = ''.join(full_response) if full_response else f'Workflow completed for: {text}'
        print(f"--------------------\nReturning from FoundryWorkflowAgent.invoke(\"{text}\"):\n\n{retval}\n--------------------\n")
        return retval


class FoundryWorkflowAgentExecutor(AgentExecutor):
    """Foundry Workflow Agent Executor."""

    def __init__(self):
        self.agent = FoundryWorkflowAgent()

    async def execute(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        raw_text = get_message_text(context.message) if context.message else ''

         # TODO inspect and return "metadata":{ "copilotstudio.microsoft.com/a2a/chathistory"....} to reconstruct conversation history in the agent.invoke method for better context handling in the workflow

        # The agent.invoke now handles streaming events to event_queue
        result = await self.agent.invoke(raw_text)

        history = []
        if context.message:
            history.append(context.message)
        history.append(new_agent_text_message(result))
        completed_task = Task(
                id=context.task_id,
                context_id=context.context_id,
                status=TaskStatus(state=TaskState.completed),
                history=history
        )

        
        await event_queue.enqueue_event(completed_task)


    async def cancel(
        self, context: RequestContext, event_queue: EventQueue
    ) -> None:
        raise Exception('cancel not supported')
