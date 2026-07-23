公司內的行銷同仁(之後稱為AM), 會上傳一份從其他系統收集來的contacts清單到 Salesforce
目的是要挑選出適合參加Event的Contact.

1. 我要把檔案取出來並且將名單跟現有的 Salesforce Contacts比較, 若上傳的記錄包含更新某個Contact的資訊 (例如升職或換公司), 就需要更新 Contact.
2. AM可以在Salesforce 創造一個 "Event" object, 然後選擇他負責的 Account底下的 Contacts, 勾選後加入此 Event
3. AM可以選擇將 Event內的Contact list送出給 Account Owner (Salesforce內定義的角色, 一般是AM的manager/director) 這時需要送信通知, 讓他可以在Salesforce web or ios APP上面簽核 approve or reject 某個contact能否參加event, 需要有 "select all" 按鈕.
4. Account Owner簽核過後, AM會收到Salesforce寄出的通知信, 然後可以到 event 將被同意過的contact export.