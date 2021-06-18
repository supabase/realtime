/**
 * Index is the "Workflows page"
 */

import { Menu, Button, Input, Modal, Typography } from '@supabase/ui'
import { useState, useEffect } from 'react'


export default function NewWorkflowModal({ visible, onCancel, onConfirm }) {
  const [name, setName] = useState('')
  const [trigger, setDefaultTrigger] = useState('public:users')
  const [default_execution_type, setDefaultExecutionType] = useState('transient')
  const [definition, setDefinition] = useState({})

  // TODO: take out trigger Pass State
  useEffect(() => {
    setDefinition({
      "StartAt": trigger,
      "States": {
        [trigger]: {
          "Type": "Pass",
          "Next": "TriggerEmail"
        },
        "TriggerEmail": {
          "Type": "Task",
          "Resource": "email",
          "Parameters": {
              "payload": {
                "to": ["to@test.com", "to2@test.com"],
                "from": "from@test.com",
                "subject": "Test Test",
                "text_body.$": "$.changes",
                "html_body": "<strong>Hey there!</strong>"
              }
          },
          "Next": "Complete"
        },
        "Complete": {
          "Type": "Succeed"
        }
      }
    })
  }, [trigger])

  return (
    <Modal
      visible={visible}
      onCancel={onCancel}
      onConfirm={() => {
        const payload = { name, default_execution_type, trigger, definition }
        setName('')
        return onConfirm(payload)
      }}
    >
      <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} />
      <Input label="Name" value={trigger} onChange={(e) => setDefaultTrigger(e.target.value)} />
    </Modal>
  )
}
