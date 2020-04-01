--[[ 
    NFT交易合约代理模式 - 合约代持买卖双方资产，买卖交易过程仅转移资产使用权，收取固定分配比例的手续费。
    注意：仅作 demo & POC 示例, 没有考虑订单过期后重新挂单会失败等情况，生产环境慎用！
--]]

-- 私有帮助函数
local func_datetime_from_string

--[[table { nft资产委托代理表
    nft_asset_id: table{
        principal: 委托人
        delegation_time: 委托时间
    }
}
--]]
local tbl_nft_delegations

--[[table { 当前订单列表
    nft_asset_id: table{
        seller: 出售人
        nft_asset_id：所出售的非同质资产的id
        price_amount：出售价格
        price_symbol：出售价格的资产符号
        memo：附加信息
        expiration_time：出售单过期时间
        sell_time: 挂单时间
    }
}
--]]
local tbl_nft_orders

--[[table { 历史成交订单列表
    deal_time: table{
        seller: 出售人
        buyer: 购买人
        nft_asset_id：所出售的非同质资产的id
        price_amount：出售价格
        price_symbol：出售价格的资产符号
        memo：附加信息
        expiration_time：出售单过期时间
        deal_time: 成交时间
    }
}
--]]
local tbl_nft_deals

--[[table { 交易手续费率配置
        account:ration 账户提成比例配置对，如 kokko:0.05 表示给用户 kokko 提取 5% 的手续费用
    }
}
--]]
local tbl_charge_settings

--[[ 初始化操作
参数:
    world_view: nft 资产所在的世界观
    commissions_json: 扣除手续费配置参数json字符串，如{"kokko":0.05}表示给用户kokko提取5%的手续费用
--]] 
function init(world_view,commissions_json)
    assert(chainhelper:is_owner(),'chainhelper:is_owner()')
    assert(commissions_json,'charge settings json must be set')

    -- 读取参数
    read_list={public_data={is_init=true}}
    chainhelper:read_chain()
    assert(public_data.is_init==nil,'public_data.is_init==nil')

    -- 保存初始化数据
    commissions=cjson.decode(commissions_json)
    public_data.tbl_charge_settings=commissions
    public_data.is_init=true
    public_data.world_view=world_view
    write_list={public_data={is_init=true,world_view=true,tbl_charge_settings=true}}
    chainhelper:write_chain()
end


--[[ 创建游戏中的nft道具资产
参数:
    game_user: 游戏中拥有道具的玩家
    item_desc_json: 道具基本描述信息
--]] 
function create_nft_item(game_user,item_desc_json)
    assert(chainhelper:is_owner(),'chainhelper:is_owner()')

    read_list={public_data={is_init=true,world_view=true}}
    chainhelper:read_chain()

    local world_view=public_data.world_view
    assert(world_view,'public_data.world_view ~= nil')

    -- 创建 nft 资产，由合约 owner 代持有
    local delegate=contract_base_info.owner
    local asset_id=chainhelper:create_nh_asset(delegate,'COCOS',world_view,item_desc_json,true)
    -- 向游戏玩家转移使用权
    chainhelper:change_nht_active_by_owner(game_user,asset_id,true)
    -- TODO 目前尚不支持锁定操作被出售的 NFT（功能尚待开发）
    
    read_list={public_data={tbl_nft_delegations=true}}
    chainhelper:read_chain()

    -- 保存 NFT 资产委托关系
    tbl_nft_delegations=public_data.tbl_nft_delegations
    if (not tbl_nft_delegations) then
        tbl_nft_delegations={} 
        public_data.tbl_nft_delegations=tbl_nft_delegations
    end
    local delegation_time=date('%Y-%m-%dT%H:%M:%S', chainhelper:time())
    tbl_nft_delegations[asset_id]={principal=game_user,delegation_time=delegation_time}

    write_list=read_list
    chainhelper:write_chain()
end

--[[ 出售 NFT 游戏道具
参数:
    nft_asset_id：所出售的非同质资产的id
    price_amount：出售价格
    price_symbol：出售价格的资产符号
    memo：附加信息
    expiration_time：订单过期时间
--]] 
function sell_nft_item(nft_asset_id,price_amount,price_symbol,memo,expiration_time)
    assert(nft_asset_id, "nft_asset_id ~= nil")
    assert((price_amount+0)>0, "price_amount > 0")
    assert(price_symbol=='COCOS', "price_symbol == 'COCOS'")

    -- 检查是否为有效过期时间
    assert(expiration_time, "expiration_time ~= nil")
    expire_dt=func_datetime_from_string(expiration_time)
    assert(expire_dt.year and expire_dt.month and expire_dt.day and expire_dt.hour and expire_dt.minute and expire_dt.second,
        "expiration_time format should be like %Y-%m-%dT%H:%M:%S")
    -- 检查是否过期
    local pub_time=date('%Y-%m-%dT%H:%M:%S', chainhelper:time())
    assert(pub_time<expiration_time, "pub_time < expiration_time")

    read_list={public_data={is_init=true,tbl_nft_delegations=true,tbl_nft_orders=true}}
    chainhelper:read_chain()
    assert(public_data.is_init==true,'public_data.is_init==true')

    -- 检查是否存在当前NFT资产的订单
    tbl_nft_orders=public_data.tbl_nft_orders
    if (tbl_nft_orders) then
        assert(not tbl_nft_orders[nft_asset_id], "nft asset order already exists")
    else
        tbl_nft_orders={}
        public_data.tbl_nft_orders=tbl_nft_orders
    end
    
    -- 检查代理关系
    tbl_nft_delegations=public_data.tbl_nft_delegations
    assert(tbl_nft_delegations[nft_asset_id], "tbl_nft_delegations[nft_asset_id] ~= nil")

    local owner=contract_base_info.owner
    -- 向 owner 转移使用权
    chainhelper:transfer_nht_active_from_caller(owner,nft_asset_id,true)
 
     -- 生成 NFT 卖单
     local seller=contract_base_info.caller
     tbl_nft_orders[nft_asset_id]={
         seller=seller,nft_asset_id=nft_asset_id,price_amount=price_amount,price_symbol=price_symbol,
         memo=memo,expiration_time=expiration_time,sell_time=pub_time
     }

     write_list={public_data={tbl_nft_orders=true}}
     chainhelper:write_chain()
end

--[[ 购买 NFT 资产
参数:
    nft_asset_id：所出售的非同质资产的id
--]] 
function buy_nft_item(nft_asset_id)
    assert(nft_asset_id, "nft_asset_id ~= nil")

    read_list={public_data={is_init=true,tbl_nft_orders=true,tbl_charge_settings=true}}
    chainhelper:read_chain()
    assert(public_data.is_init==true,'public_data.is_init==true')

     -- 检查订单是否存在
    tbl_nft_orders=public_data.tbl_nft_orders
    nft_order=tbl_nft_orders[nft_asset_id]
    assert(nft_order, "nft asset order not exists")

    -- 检查订单是否过期
    local buy_time=date('%Y-%m-%dT%H:%M:%S', chainhelper:time())
    assert(buy_time<nft_order.expiration_time, "buy_time < expiration_time")

    -- 买方将 token 转入 owner后，由owner根据配置表进行收益分配
    local buyer=contract_base_info.caller
    chainhelper:transfer_from_caller(contract_base_info.owner,nft_order.price_amount,nft_order.price_symbol,true) --[[转入代币]]
    -- TODO 目前尚不支持解锁操作被转入的 NFT（功能尚待开发）
    chainhelper:change_nht_active_by_owner(buyer,nft_asset_id,true)--[[转出NFT使用权]]
    -- TODO 目前尚不支持锁定操作被出售的 NFT（功能尚待开发）

    -- 手续费结算
    local total_fees=0
    commissions=public_data.tbl_charge_settings
    if (commissions) then 
        for k, v in pairs(commissions) do
            local amount=math.floor(nft_order.price_amount*v)
            total_fees=total_fees+amount

            if (k ~= contract_base_info.owner and amount > 0) then
                chainhelper:transfer_from_owner(k,amount,nft_order.price_symbol,true)
            end
        end
    end

    -- 剩余部分转移给卖方
    local left=nft_order.price_amount-total_fees
    if (left>0) then 
        chainhelper:transfer_from_owner(nft_order.seller,left,nft_order.price_symbol,true)
    end
    
    -- 删除当前挂单
    tbl_nft_orders[nft_asset_id]=nil

    -- 记录历史成交
    read_list={public_data={tbl_nft_deals=true}}
    chainhelper:read_chain()

    tbl_nft_deals=public_data.tbl_nft_deals
    if (not tbl_nft_deals) then
        tbl_nft_deals={}
        public_data.tbl_nft_deals=tbl_nft_deals
    end
    local nft_deal={
        seller=nft_order.seller,nft_asset_id=nft_order.nft_asset_id,price_amount=nft_order.price_amount,price_symbol=nft_order.price_symbol,
        memo=nft_order.memo,expiration_time=nft_order.expiration_time,sell_time=nft_order.sell_time,buyer=buyer,deal_time=buy_time
    }
    tbl_nft_deals[buy_time]=nft_deal

    write_list={public_data={tbl_nft_orders=true,tbl_nft_deals=true}}
    chainhelper:write_chain()
end

-- 从例如 '2019-09-12T05:23:30' 的日期字符串获取日期时间对象
func_datetime_from_string=function(dt_str)
    local y, m, d, h, mt, s = string.match(dt_str, '(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)$')
    return {year=y+0, month=m+0, day=d+0, hour=h+0, minute=mt+0, second=s+0}
end