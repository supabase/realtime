import React, { useState, useEffect } from 'react';
import { Form, Input, Button, Card, Table, Tag, Row, Col } from 'antd';
import { RealtimeClient } from '@supabase/realtime-js'

export default function Index() {
  const [form] = Form.useForm();
  const [dataSource, setDataSource] = useState([]);
  const [connButton, setConnButtonState] = useState({ loading: false, value: "Connect" });


  useEffect(() => {
    form.setFieldsValue({
      host: localStorage.getItem('host'),
      token: localStorage.getItem('token'),
    })
  }, [])

  const onFinish = ({ host, token }) => {
    setConnButtonState({ loading: true, value: "Connection ..." })
    localStorage.setItem("host", host)
    localStorage.setItem("token", token)
    let socket = new RealtimeClient(host, { params: { apikey: token } })
    socket.connect()
    let channel = socket.channel('realtime:*', { user_token: token })
    channel.on('*', msg => {
      console.log('Got a message', msg)
      dataSource.unshift({
        key: dataSource.length + 1,
        type: msg.type,
        table: msg.schema + "." + msg.table,
        record: JSON.stringify(msg.record),
        old_record: JSON.stringify(msg.old_record),
        errors: JSON.stringify(msg.errors),
        columns: JSON.stringify(msg.columns),
        ts: msg.commit_timestamp
      })
      setDataSource([...dataSource])
    })
    channel
      .subscribe()
      .receive('ok', () => {
        console.log('Connecting')
        setConnButtonState({ loading: false, value: "Connected" })
      })
      .receive('error', () => console.log('Failed'))
      .receive('timeout', () => console.log('Waiting...'))
  };

  const formItemLayout = {
    labelCol: { span: 4 },
    wrapperCol: { span: 14 },
  };
  const buttonItemLayout = {
    wrapperCol: { span: 14, offset: 4 }
  }

  const columns =
    ["type", "table", "record", "old_record", "errors", "columns", "ts"]
      .map(el => {
        let column = {
          title: el,
          dataIndex: el,
          key: el
        }
        if (el == "type") {
          column['render'] = type => {
            let color = "#ccc"
            switch (type) {
              case "INSERT":
                color = "green"
                break;
              case "UPDATE":
                color = "blue"
                break;
              case "DELETE":
                color = "red"
                break;
            }
            return (
              <Tag color={color} key={type}>{type}</Tag>
            )
          }
          column['filters'] = [
            { text: 'INSERT', value: 'INSERT' },
            { text: 'UPDATE', value: 'UPDATE' },
            { text: 'DELETE', value: 'DELETE' },
          ]
          column['onFilter'] = (value, record) => record.type == value
        }
        return column
      })

  return (
    <>
      <Card>
        <Form
          {...formItemLayout}
          layout={'horizontal'}
          form={form}
          onFinish={onFinish}
        >
          <Form.Item label="Address" name={'host'}>
            <Input placeholder="input placeholder" size="large" />
          </Form.Item>
          <Form.Item label="Token" name={'token'}>
            <Input.TextArea size="large" rows={4} />
          </Form.Item>
          <Form.Item {...buttonItemLayout}>
            <Button type="primary" htmlType="submit" loading={connButton.loading}>
              {connButton.value}
            </Button>
          </Form.Item>
        </Form>
      </Card>

      <Table dataSource={dataSource} columns={columns} pagination={false} />
    </>
  );
}