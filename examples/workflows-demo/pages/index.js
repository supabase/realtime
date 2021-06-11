/**
 * Index is the "Workflows page"
 */

import { Menu, Button, Input, Modal, Typography } from '@supabase/ui'
import { useState, useEffect } from 'react'
import Layout from '../components/Layout'
import NewWorkflowModal from '../components/NewWorkflowModal'
import Flow from '../components/Flow'
import { createWorkflow, listWorkflows } from '../lib/api'

export default function Home() {
  const [workflows, setWorkflows] = useState([])
  const [visible, setVisible] = useState(false)
  const [selectedWorkflowId, setSelectedWorkflowId] = useState(null)

  function toggle() {
    setVisible(!visible)
  }

  useEffect(() => {
    fetchWorkflows()
  }, [])

  const fetchWorkflows = async () => {
    const { data, error } = await listWorkflows()

    if (data) {
      setWorkflows(data)
    }
  }

  const newWorkflow = async ({ name, definition, trigger, default_execution_type }) => {
    const { data, error } = await createWorkflow({
      name,
      definition,
      trigger,
      default_execution_type,
    })

    if (data) {
      fetchWorkflows()
    }
  }

  return (
    <Layout>
      <div className="w-64 p-4 border-r ">
        <Menu>
          <>
            <Button onClick={toggle} type="primary" block>
              New workflow
            </Button>

            <NewWorkflowModal
              visible={visible}
              onCancel={toggle}
              onConfirm={(data) => {
                console.log('data', data)
                newWorkflow(data)
                toggle()
              }}
            />
          </>

          {workflows.length > 0 && <Menu.Group title="Flows" />}
          {workflows.map((workflow) => (
            <Menu.Item key={workflow.id} onClick={() => setSelectedWorkflowId(workflow.id)}>
              {workflow.name}
            </Menu.Item>
          ))}
        </Menu>
      </div>
      <div className="flex-grow h-full w-full">
        {selectedWorkflowId ? <Flow id={selectedWorkflowId} /> : <div className="p-4">Select a flow</div>}
      </div>
    </Layout>
  )
}
