import axios from 'axios'
import { WORKFLOWS_SERVER_URL } from './constants'

const API_URL = `${WORKFLOWS_SERVER_URL}/api/workflows`

export const getWorkflow = async (id) => {
  try {
    const { data } = await axios.get(`${API_URL}/${id}`)
    if (data && data.workflow) {
      return { data: data.workflow, error: null }
    }
    else {
        throw new Error('Could not get workflow')
    }
  } catch (error) {
    console.log('error', error)
    return { data: null, error: error.message }
  }
}

export const listWorkflows = async () => {
  try {
    const { data } = await axios.get(API_URL)
    if (data && data.workflows) {
      return { data: data.workflows, error: null }
    }
    else {
        throw new Error('Could not get workflows')
    }
  } catch (error) {
    console.log('error', error)
    return { data: null, error: error.message }
  }
}

export const createWorkflow = async ({ name, definition, trigger, default_execution_type }) => {
  try {
    const { data } = await axios.post(API_URL, {
      name,
      definition,
      trigger,
      default_execution_type,
    })
    return { data, error: null }
  } catch (error) {
    console.log('error', error)
    return { data: null, error: error.message }
  }
}

export const updateWorkflow = async ({ id, definition }) => {
  try {
    const { data } = await axios.patch(`${API_URL}/${id}`, {
      definition
    })
    return { data, error: null }
  } catch (error) {
    console.log('error', error)
    return { data: null, error: error.message }
  }
}