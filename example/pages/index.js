import React, { useState, useEffect } from 'react';
import { Form, Input, Button, Card, Table, Tag, Row, Col, Tabs } from 'antd';
const { TabPane } = Tabs;
import { RealtimeClient } from '@supabase/realtime-js';
// const SupabaseClient = require('@supabase/supabase-js').SupabaseClient;

let channel = null;

export default function Index() {
  const [form] = Form.useForm();
  const [form_broadcast] = Form.useForm();
  const [dataSource, setDataSource] = useState([]);
  const [connButton, setConnButtonState] = useState({
    loading: false,
    value: 'Connect',
  });

  useEffect(() => {
    form.setFieldsValue({
      host: localStorage.getItem('host'),
      token: localStorage.getItem('token'),
    });
    form_broadcast.setFieldsValue({
      event: 'TEST',
      payload: '{"msg": 1}'
    });
  }, []);

  const onFinish = ({ host, token }) => {
    setConnButtonState({ loading: true, value: 'Connection ...' });
    localStorage.setItem('host', host);
    localStorage.setItem('token', token);
    let socket = new RealtimeClient(host, {
      params: { apikey: token, vsndate: '2022' },
    });

    channel = socket.channel('any', { configs: { broadcast: { self: true } } })

    channel
      .on("postgres_changes", { event: "*", schema: "public" }, payload => {
        console.log('DB', payload)
        dataSource.unshift({
          key: dataSource.length + 1,
          type: "DB/" + payload.eventType,
          'table/event': payload.schema + "." + payload.table,
          'record/payload': JSON.stringify(payload.new),
          old_record: JSON.stringify(payload.old),
          errors: JSON.stringify(payload.errors),
          columns: JSON.stringify(payload.columns),
          ts: payload.commit_timestamp
        })
        setDataSource([...dataSource])
      })
      .on("broadcast", { event: "*" }, payload => {
        console.log('PAYLOAD', payload)
        dataSource.unshift({
          key: dataSource.length + 1,
          type: payload.type,
          'table/event': payload.event,
          'record/payload': JSON.stringify(payload.payload)
        })
        setDataSource([...dataSource])
      })
      .on("presence", { event: "*" }, payload => {
        console.log('presence', payload)
        dataSource.unshift({
          key: dataSource.length + 1,
          type: 'presence',
          'table/event': payload.event,
          'record/payload': JSON.stringify(payload),
        })
        setDataSource([...dataSource])
      })

    channel.subscribe((status, err) => {
      console.log('status', status, err)
      if (status === 'SUBSCRIBED') {
        setConnButtonState({ loading: false, value: 'Connected' });
        const name = 'realtime_presence_' + Math.floor(Math.random() * 100);
        channel.send(
          {
            type: 'presence',
            event: 'TRACK',
            payload: { name: name, t: performance.now() },
          })
      }
    })
  };

  const onBroadcast = ({ event, payload }) => {
    payload = JSON.parse(payload)
    console.log('broadcast event', event, payload)
    channel.send({
      type: "broadcast",
      event: event,
      payload: payload
    })
  }

  const formItemLayout = {
    labelCol: { span: 4 },
    wrapperCol: { span: 14 },
  };
  const buttonItemLayout = {
    wrapperCol: { span: 14, offset: 4 },
  };

  const columns = [
    'type',
    'table/event',
    'record/payload',
    'old_record',
    'errors',
    'columns',
    'ts',
  ].map((el) => {
    let column = {
      title: el,
      dataIndex: el,
      key: el,
    };
    if (el == 'type') {
      column['render'] = (type) => {
        let color = '#ccc';
        switch (type) {
          case 'DB/INSERT':
            color = 'green';
            break;
          case 'DB/UPDATE':
            color = 'blue';
            break;
          case 'DB/DELETE':
            color = 'red';
            break;
          case 'broadcast':
            color = 'purple';
            break;
          case 'presence':
            color = 'gold';
            break;
        }
        return (
          <Tag color={color} key={type}>
            {type}
          </Tag>
        );
      };
      column['filters'] = [
        { text: 'INSERT', value: 'INSERT' },
        { text: 'UPDATE', value: 'UPDATE' },
        { text: 'DELETE', value: 'DELETE' },
      ];
      column['onFilter'] = (value, record) => record.type == value;
    }
    return column;
  });

  return (
    <>
      <Card>
        <Tabs defaultActiveKey="connection">
          <TabPane tab="Connection" key="connection">
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
                <Button
                  type="primary"
                  htmlType="submit"
                  loading={connButton.loading}
                >
                  {connButton.value}
                </Button>
              </Form.Item>
            </Form>
          </TabPane>
          <TabPane tab="Broadcast" key="broadcast">
            <Form
              {...formItemLayout}
              layout={'horizontal'}
              form={form_broadcast}
              onFinish={onBroadcast}
            >
              <Form.Item label="Event" name={'event'}>
                <Input size="large" />
              </Form.Item>
              <Form.Item label="Payload" name={'payload'}>
                <Input.TextArea size="large" rows={4} />
              </Form.Item>
              <Form.Item {...buttonItemLayout}>
                <Button
                  type="primary"
                  htmlType="submit"
                >
                  Broadcast
                </Button>
              </Form.Item>
            </Form>
          </TabPane>
        </Tabs>
      </Card>


      <Table dataSource={dataSource} columns={columns} pagination={false} />
    </>
  );
}
